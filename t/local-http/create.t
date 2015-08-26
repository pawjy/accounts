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
        url => qq<http://$host/create>,
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
} wait => $wait, n => 1, name => '/create GET';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post
        url => qq<http://$host/create>,
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
} wait => $wait, n => 1, name => '/create no auth';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post
        url => qq<http://$host/create>,
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
      is $status, 400;
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/create no session';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  session ($c)->then (sub {
    my $session = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/create>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {sk_context => 'tests', sk => $session->{sk}},
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
        ok $json->{account_id};
      } $c;
      return Promise->new (sub {
        my ($ok, $ng) = @_;
        http_post
            url => qq<http://$host/info>,
            header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
            params => {sk_context => 'tests', sk => $session->{sk}},
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
        my $json2 = $_[0];
        test {
          is $json2->{account_id}, $json->{account_id};
          is $json2->{name}, $json->{account_id};
          is $json2->{user_status}, 1;
          is $json2->{admin_status}, 1;
          is $json2->{terms_version}, 0;
        } $c;
      });
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 6, name => '/create has anon session';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  Promise->resolve->then (sub {
    my $session = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/create>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {sk => 'gfaeaaaaa', sk_context => 'tests'},
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
    });
  })->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 400;
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/create bad session';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  session ($c)->then (sub {
    my $session = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/create>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {
            sk_context => 'tests', sk => $session->{sk},
            name => "\x{65000}",
            user_status => 2,
            admin_status => 6,
            terms_version => 5244,
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
        ok $json->{account_id};
      } $c;
      return Promise->new (sub {
        my ($ok, $ng) = @_;
        http_post
            url => qq<http://$host/info>,
            header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
            params => {sk_context => 'tests', sk => $session->{sk}},
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
        my $json2 = $_[0];
        test {
          is $json2->{account_id}, $json->{account_id};
          is $json2->{name}, "\x{65000}";
          is $json2->{user_status}, 2;
          is $json2->{admin_status}, 6;
          is $json2->{terms_version}, 255;
        } $c;
      });
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 6, name => '/create with options';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
