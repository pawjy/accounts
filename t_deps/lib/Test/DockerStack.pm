package Test::DockerStack;
use strict;
use warnings;
our $VERSION = '1.0';
use Path::Tiny;
use File::Temp;
use Promise;
use Promised::Flow;
use Promised::Command;
use Promised::Command::Signals;
use Promised::File;
use JSON::PS;

sub new ($$) {
  my ($class, $def) = @_;
  my $temp = File::Temp->newdir;
  return bless {
    def => $def,
    _temp => $temp, # files removed when destroyed
    temp_path => path ($temp)->absolute,
    self_pid => $$,
  }, $class;
} # new

sub logs ($;$) {
  if (@_ > 1) {
    $_[0]->{logs} = $_[1];
  }
  return $_[0]->{logs} // sub {
    my $v = $_[0];
    $v .= "\n" unless $v =~ /\n\z/;
    warn $v;
  };
} # logs

sub propagate_signal ($;$) {
  if (@_ > 1) {
    $_[0]->{propagate_signal} = $_[1];
  }
  return $_[0]->{propagate_signal};
} # propagate_signal

sub signal_before_destruction ($;$) {
  if (@_ > 1) {
    $_[0]->{signal_before_destruction} = $_[1];
  }
  return $_[0]->{signal_before_destruction};
} # signal_before_destruction

sub stack_name ($;$) {
  if (@_ > 1) {
    $_[0]->{stack_name} = $_[1];
  }
  return $_[0]->{stack_name} //= rand;
} # stack_name

sub start ($) {
  my $self = $_[0];
  
  return Promise->reject ("Already running") if $self->{running};
  $self->{running} = 1;

  my $def = $self->{def};
  $def->{version} //= '3.3';

  my $logs = $self->logs;
  my $propagate = $self->propagate_signal;
  my $before = $self->signal_before_destruction;

  my $compose_path = $self->{temp_path}->child ('docker-compose.yml');
  my $stack_name = $self->stack_name;
  
  my $out;
  my $start = sub {
    $out = '';
    my $start_cmd = Promised::Command->new ([
      'docker', 'stack', 'deploy',
      '--compose-file', $compose_path,
      $stack_name,
    ]);
    my $stderr = '';
    $start_cmd->stdout (sub {
      my $w = $_[0];
      Promise->new (sub { $_[0]->($logs->($w)) });
    });
    $start_cmd->stderr (sub {
      my $w = $_[0];
      $stderr .= $w if defined $w;
      Promise->new (sub { $_[0]->($logs->($w)) });
    });
    $start_cmd->propagate_signal ($propagate);
    $start_cmd->signal_before_destruction ($before);
    return $start_cmd->run->then (sub {
      return $start_cmd->wait;
    })->then (sub {
      my $result = $_[0];
      if ($result->exit_code == 1 and
          $stderr =~ /^this node is not a swarm manager./) {
        return $result;
      }
      die $result unless $result->exit_code == 0;
      return undef;
    });
  }; # $start

  if ($self->{propagate_signal}) {
    for my $name (qw(INT TERM QUIT)) {
      $self->{signal_handlers}->{$name}
          = Promised::Command::Signals->add_handler ($name => sub {
              return $self->stop;
            });
    }
  }

  return Promised::File->new_from_path ($compose_path)->write_byte_string (perl2json_bytes $def)->then (sub {
    return $start->()->then (sub {
      my $error = $_[0];
      if (defined $error) {
        my $init_cmd = Promised::Command->new ([
          'docker', 'swarm', 'init',
          '--advertise-addr', '127.0.0.1',
        ]);
        return $init_cmd->run->then (sub {
          return $init_cmd->wait;
        })->then (sub {
          my $result = $_[0];
          die $result unless $result->exit_code == 0;
          return $start->()->then (sub {
            my $error = $_[0];
            die $error if defined $error;
          });
        });
      } # $error
    });
  })->catch (sub {
    my $e = $_[0];
    return $self->stop->then (sub { die $e }, sub { die $e });
  });
} # start

sub stop ($) {
  my $self = $_[0];
  return Promise->resolve unless $self->{running};

  my $stop_cmd = Promised::Command->new ([
    'docker', 'stack', 'rm', $self->stack_name,
  ]);
  return promised_cleanup {
    delete $self->{signal_handlers};
    delete $self->{running};
  } $stop_cmd->run->then (sub {
    return $stop_cmd->wait;
  })->then (sub {
    my $result = $_[0];
    die $result unless $result->exit_code == 0;
  })->catch (sub {
    my $error = $_[0];
    $self->logs->("Failed to stop the docker containers: $error\n");
  });
} # stop

sub DESTROY ($) {
  my $self = $_[0];
  if ($self->{running} and
      defined $self->{self_pid} and $self->{self_pid} == $$) {
    require Carp;
    warn "$$: $self is to be destroyed while the docker is still running", Carp::shortmess;
    if (defined $self->{signal_before_destruction}) {
      $self->stop;
    }
  }
} # DESTROY

1;

=head1 LICENSE

Copyright 2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
