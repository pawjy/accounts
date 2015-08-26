use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Test::More;
use Test::X1;
use Promise;
use Web::UserAgent::Functions qw(http_post http_get);
use JSON::PS;

my $wait = web_server;

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_get
        url => qq<http://$host/profiles>,
        header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
        anyevent => 1,
        max_redirect => 0,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } else {
            $ng->($res->code);
          }
        };
  })->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 405;
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/profiles GET';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post
        url => qq<http://$host/profiles>,
        anyevent => 1,
        max_redirect => 0,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } else {
            $ng->($res->code);
          }
        };
  })->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 401;
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/profiles no auth';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post
        url => qq<http://$host/profiles>,
        header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
        anyevent => 1,
        max_redirect => 0,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } else {
            $ng->($res->code);
          }
        };
  })->then (sub {
    my $json = $_[0];
    test {
      is ref $json->{accounts}, 'HASH';
      is 0+keys %{$json->{accounts} or {}}, 0;
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 2, name => '/profiles no account_id';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post
        url => qq<http://$host/profiles>,
        header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
        params => {
          account_id => [12, 4244444, 'abacee'],
        },
        anyevent => 1,
        max_redirect => 0,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } else {
            $ng->($res->code);
          }
        };
  })->then (sub {
    my $json = $_[0];
    test {
      is ref $json->{accounts}, 'HASH';
      is 0+keys %{$json->{accounts} or {}}, 0;
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 2, name => '/profiles bad account_id';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  session ($c, account => {name => "\x{5000}"})->then (sub {
    my $a1 = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/profiles>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {
            account_id => $a1->{account_id},
          },
          anyevent => 1,
          max_redirect => 0,
          cb => sub {
            my $res = $_[1];
            if ($res->code == 200) {
              $ok->(json_bytes2perl $res->content);
            } else {
              $ng->($res->code);
            }
          };
    })->then (sub {
      my $json = $_[0];
      test {
        my $data = $json->{accounts}->{$a1->{account_id}};
        is $data->{account_id}, $a1->{account_id};
        is $data->{name}, "\x{5000}";
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 2, name => '/profiles with account_id, matched';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  session ($c, account => {name => "\x{5000}", user_status => 2})->then (sub {
    my $a1 = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/profiles>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {
            account_id => $a1->{account_id},
            user_status => [1, 3],
          },
          anyevent => 1,
          max_redirect => 0,
          cb => sub {
            my $res = $_[1];
            if ($res->code == 200) {
              $ok->(json_bytes2perl $res->content);
            } else {
              $ng->($res->code);
            }
          };
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{accounts}->{$a1->{account_id}}, undef;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 1, name => '/profiles with account_id, user_status filtered';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  session ($c, account => {name => "\x{5000}", admin_status => 2})->then (sub {
    my $a1 = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/profiles>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {
            account_id => $a1->{account_id},
            admin_status => [1, 3],
          },
          anyevent => 1,
          max_redirect => 0,
          cb => sub {
            my $res = $_[1];
            if ($res->code == 200) {
              $ok->(json_bytes2perl $res->content);
            } else {
              $ng->($res->code);
            }
          };
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{accounts}->{$a1->{account_id}}, undef;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 1, name => '/profiles with account_id, admin_status filtered';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
