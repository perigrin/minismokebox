package App::SmokeBox::Mini;

use strict;
use warnings;
use Pod::Usage;
use Config::Tiny;
use File::Spec;
use Cwd;
use Getopt::Long;
use Time::Duration qw(duration_exact);
use POE;
use POE::Component::SmokeBox;
use POE::Component::SmokeBox::Smoker;
use POE::Component::SmokeBox::Job;
use POE::Component::SmokeBox::Dists;
use POE::Component::SmokeBox::Recent;

use vars qw($VERSION);

use constant CPANURL => 'ftp://cpan.cpantesters.org/CPAN/';

$VERSION = '0.20';

$ENV{PERL5_MINISMOKEBOX} = $VERSION;

sub _smokebox_dir {
  return $ENV{PERL5_SMOKEBOX_DIR} 
     if  exists $ENV{PERL5_SMOKEBOX_DIR} 
     && defined $ENV{PERL5_SMOKEBOX_DIR};

  my @os_home_envs = qw( APPDATA HOME USERPROFILE WINDIR SYS$LOGIN );

  for my $env ( @os_home_envs ) {
      next unless exists $ENV{ $env };
      next unless defined $ENV{ $env } && length $ENV{ $env };
      return $ENV{ $env } if -d $ENV{ $env };
  }

  return cwd();
}

sub _read_config {
  my $smokebox_dir = File::Spec->catdir( _smokebox_dir(), '.smokebox' );
  return unless -d $smokebox_dir;
  my $conf_file = File::Spec->catfile( $smokebox_dir, 'minismokebox' );
  return unless -e $conf_file;
  my $Config = Config::Tiny->read( $conf_file );
  if ( defined $Config->{_} ) {
	return map { $_, $Config->{_}->{$_} } grep { exists $Config->{_}->{$_} }
		qw(debug perl indices recent backend url);
  }
  return;
}

sub _get_jobs_from_file {
  my $jobs = shift || return;
  unless ( open JOBS, "< $jobs" ) {
     warn "Could not open '$jobs' '$!'\n";
     return;
  }
  my @jobs;
  while (<JOBS>) {
    chomp;
    push @jobs, $_;
  }
  close JOBS;
  return @jobs;
}

sub _display_version {
  print "minismokebox version ", $VERSION, 
    ", powered by POE::Component::SmokeBox ", POE::Component::SmokeBox->VERSION, "\n\n";
  print <<EOF;
Copyright (C) 2009 Chris 'BinGOs' Williams
This module may be used, modified, and distributed under the same terms as Perl itself. 
Please see the license that came with your Perl distribution for details.
EOF
  exit;
}

sub run {
  my $package = shift;
  my %config = _read_config();
  my $version;
  GetOptions(
    "help"      => sub { pod2usage(1); },
    "version"   => sub { $version = 1 },
    "debug"     => \$config{debug},
    "perl=s" 	  => \$config{perl},
    "indices"   => \$config{indices},
    "recent"    => \$config{recent},
    "jobs=s"    => \$config{jobs},
    "backend=s" => \$config{backend},
    "author=s"  => \$config{author},
    "package=s" => \$config{package},
    "phalanx"   => \$config{phalanx},
    "url=s"	  => \$config{url},
    "reverse"   => \$config{reverse},
  ) or pod2usage(2);

  _display_version() if $version;

  $config{perl} = $^X unless $config{perl} and -e $config{perl};
  $ENV{PERL5_SMOKEBOX_DEBUG} = 1 if $config{debug};
  $ENV{AUTOMATED_TESTING} = 1;   # We need this because some backends do not set it.
  $ENV{PERL_MM_USE_DEFAULT} = 1; # And this.
  $ENV{PERL_EXTUTILS_AUTOINSTALL} = '--defaultdeps'; # Got this from CPAN::Reporter::Smoker. Cheers, xdg!

  if ( $config{jobs} and -e $config{jobs} ) {
     my @jobs = _get_jobs_from_file( $config{jobs} );
     $config{jobs} = \@jobs if scalar @jobs;
  }

  print "Running minismokebox with options:\n";
  printf("%-20s %s\n", $_, $config{$_}) 
	for grep { defined $config{$_} } qw(debug indices perl jobs backend author package phalanx reverse url);

  my $self = bless \%config, $package;

  $self->{sbox} = POE::Component::SmokeBox->spawn( 
	smokers => [
	   POE::Component::SmokeBox::Smoker->new(
		perl => $self->{perl},
	   ),
	],
  );

  $self->{session_id} = POE::Session->create(
	object_states => [
	   $self => { recent => '_submission', dists => '_submission', },
	   $self => [qw(_start _stop _check _indices _smoke _search)],
	],
	heap => $self,
  )->ID();

  $poe_kernel->run();
  return 1;
}

sub _start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $self->{session_id} = $_[SESSION]->ID();
  # Run a check to make sure the backend exists in the designated perl
  $kernel->post( $self->{sbox}->session_id(), 'submit', event => '_check', job => 
     POE::Component::SmokeBox::Job->new(
	( $self->{backend} ? ( type => $self->{backend} ) : () ),
	command => 'check',
     ),
  );
  $self->{stats} = {
	started => time(),
	totaljobs => 0,
	avg_run => 0,
	min_run => 0,
	max_run => 0,
	_sum => 0,
	idle => 0,
	excess => 0,
  };
  return;
}

sub _stop {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  $kernel->call( $self->{sbox}->session_id(), 'shutdown' );
  my $finish = time();
  my $cumulative = duration_exact( $finish - $self->{stats}->{started} );
  my @stats = map { $self->{stats}->{$_} } qw(totaljobs idle excess avg_run min_run max_run);
  $stats[$_] = duration_exact( $stats[$_] ) for 3 .. 5;
  print "minismokebox started at: \t", scalar localtime($self->{stats}->{started}), "\n";
  print "minismokebox finished at: \t", scalar localtime($finish), "\n";
  print "minismokebox ran for: \t", $cumulative, "\n";
  print "minismokebox tot jobs:\t", $stats[0], "\n";
  print "minismokebox idle kills:\t", $stats[1], "\n" if $stats[1];
  print "minismokebox excess kills:\t", $stats[2], "\n" if $stats[2];
  print "minismokebox avg run: \t", $stats[3], "\n";
  print "minismokebox min run: \t", $stats[4], "\n";
  print "minismokebox max run: \t", $stats[5], "\n";
  return;
}

sub _check {
  my ($kernel,$self,$data) = @_[KERNEL,OBJECT,ARG0];
  my ($result) = $data->{result}->results;
  unless ( $result->{status} == 0 ) {
     my $backend = $self->{backend} || 'CPANPLUS::YACSmoke';
     warn "The specified perl '$self->{perl}' does not have backend '$backend' installed, aborting\n";
     return;
  }
  if ( $self->{indices} ) {
     $kernel->post( $self->{sbox}->session_id(), 'submit', event => '_indices', job => 
        POE::Component::SmokeBox::Job->new(
	   ( $self->{backend} ? ( type => $self->{backend} ) : () ),
	   command => 'index',
        ),
     );
     return;
  }
  $kernel->yield( '_search' );
  return;
}

sub _indices {
  my ($kernel,$self,$data) = @_[KERNEL,OBJECT,ARG0];
  my ($result) = $data->{result}->results;
  unless ( $result->{status} == 0 ) {
     my $backend = $self->{backend} || 'CPANPLUS::YACSmoke';
     warn "There was a problem with the reindexing\n";
     return;
  }
  $kernel->yield( '_search' );
  return;
}

sub _search {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  if ( $self->{jobs} and ref $self->{jobs} eq 'ARRAY' ) {
     foreach my $distro ( @{ $self->{jobs} } ) {
        print "Submitting: $distro\n";
        $kernel->post( $self->{sbox}->session_id(), 'submit', event => '_smoke', job => 
           POE::Component::SmokeBox::Job->new(
	      ( $self->{backend} ? ( type => $self->{backend} ) : () ),
	      command => 'smoke',
	      module  => $distro,
           ),
        );
     }
  }
  if ( $self->{recent} ) {
    POE::Component::SmokeBox::Recent->recent( 
        url => $self->{url} || CPANURL,
        event => 'recent',
    );
  }
  if ( $self->{package} ) {
    warn "Doing a distro search, this may take a little while\n";
    POE::Component::SmokeBox::Dists->distro(
        event => 'dists',
        search => $self->{package},
        url => $self->{url} || CPANURL,
    );
  }
  if ( $self->{author} ) {
    warn "Doing an author search, this may take a little while\n";
    POE::Component::SmokeBox::Dists->author(
        event => 'dists',
        search => $self->{author},
        url => $self->{url} || CPANURL,
    );
  }
  if ( $self->{phalanx} ) {
    warn "Doing a phalanx search, this may take a little while\n";
    POE::Component::SmokeBox::Dists->phalanx(
        event => 'dists',
        url => $self->{url} || CPANURL,
    );
  }
  return if !$self->{recent} and ( $self->{package} or $self->{author} or $self->{phalanx} or ( $self->{jobs} and ref $self->{jobs} eq 'ARRAY' ) );
  POE::Component::SmokeBox::Recent->recent( 
      url => $self->{url} || CPANURL,
      event => 'recent',
  );
  return;
}

sub _submission {
  my ($kernel,$self,$state,$data) = @_[KERNEL,OBJECT,STATE,ARG0];
  if ( $data->{error} ) {
     warn $data->{error}, "\n";
     return;
  }
  if ( $state eq 'recent' and $self->{reverse} ) {
     @{ $data->{$state} } = reverse @{ $data->{$state} };
  }
  foreach my $distro ( @{ $data->{$state} } ) {
     print "Submitting: $distro\n";
     $kernel->post( $self->{sbox}->session_id(), 'submit', event => '_smoke', job => 
        POE::Component::SmokeBox::Job->new(
	   ( $self->{backend} ? ( type => $self->{backend} ) : () ),
	   command => 'smoke',
	   module  => $distro,
        ),
     );
  }
  return;
}

sub _smoke {
  my ($kernel,$self,$data) = @_[KERNEL,OBJECT,ARG0];
  my $dist = $data->{job}->module();
  my ($result) = $data->{result}->results;
  print "Distribution: '$dist' finished with status '$result->{status}'\n";
  my $run_time = $result->{end_time} - $result->{start_time};
  $self->{stats}->{max_run} = $run_time if $run_time > $self->{stats}->{max_run};
  $self->{stats}->{min_run} = $run_time if $self->{stats}->{min_run} == 0;
  $self->{stats}->{min_run} = $run_time if $run_time < $self->{stats}->{min_run};
  $self->{stats}->{_sum} += $run_time;
  $self->{stats}->{totaljobs}++;
  $self->{stats}->{avg_run} = $self->{stats}->{_sum} / $self->{stats}->{totaljobs};
  $self->{stats}->{idle}++ if $result->{idle_kill};
  $self->{stats}->{excess}++ if $result->{excess_kill};
  $self->{_jobs}--;
  return;
}

'smoke it!';
__END__

=head1 NAME

App::SmokeBox::Mini - the guts of the minismokebox command

=head1 SYNOPSIS

  #!/usr/bin/perl
  use strict;
  use warnings;
  BEGIN { eval "use Event;"; }
  use App::SmokeBox::Mini;
  App::SmokeBox::Mini->run();

=head2 run

This method is called by L<minismokebox> to do all the work.

=head1 AUTHOR

Chris C<BinGOs> Williams <chris@bingosnet.co.uk>

=head1 LICENSE

Copyright E<copy> Chris Williams

This module may be used, modified, and distributed under the same terms as Perl itself. Please see the license that came with your Perl distribution for details.

=cut
