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
        url => qq<http://$host/keygen>,
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
} wait => $wait, n => 1, name => '/keygen GET';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post
        url => qq<http://$host/keygen>,
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
} wait => $wait, n => 1, name => '/keygen no auth';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post
        url => qq<http://$host/keygen>,
        header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
        params => {server => 'ssh'},
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
} wait => $wait, n => 1, name => '/keygen no session';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  session ($c)->then (sub {
    my $session = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/keygen>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {
            sk_context => 'tests', sk => $session->{sk},
            server => 'ssh',
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
    })->then (sub { test { ok 0 } $c }, sub {
      my $status = $_[0];
      test {
        is $status, 400;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 1, name => '/keygen has anon session';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  Promise->resolve->then (sub {
    my $session = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/keygen>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {
            sk => 'gfaeaaaaa', sk_context => 'tests',
            server => 'ssh',
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
    });
  })->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 400;
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/keygen bad session';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  session ($c, account => 1)->then (sub {
    my $session = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/keygen>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {
            sk_context => 'tests', sk => $session->{sk},
            server => '',
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
    })->then (sub { test { ok 0 } $c }, sub {
      my $status = $_[0];
      test {
        is $status, 400;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 1, name => '/keygen bad server';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  my $json0;
  session ($c, account => 1)->then (sub {
    my $session = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/keygen>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {
            sk_context => 'tests', sk => $session->{sk},
            server => 'ssh',
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
        is ref $json, 'HASH';
      } $c;
      return Promise->new (sub {
        my ($ok, $ng) = @_;
        http_post
            url => qq<http://$host/token>,
            header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
            params => {
              sk_context => 'tests', sk => $session->{sk},
              server => 'ssh',
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
        $json0 = my $json = $_[0];
        test {
          like $json->{access_token}->[0], qr{^ssh-dss \S+};
          unlike $json->{access_token}->[0], qr{PRIVATE KEY};
          like $json->{access_token}->[1], qr{PRIVATE KEY};
        } $c;
      });
    })->then (sub {
      return Promise->new (sub {
        my ($ok, $ng) = @_;
        http_post
            url => qq<http://$host/keygen>,
            header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
            params => {
              sk_context => 'tests', sk => $session->{sk},
              server => 'ssh',
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
      });
    })->then (sub {
      return Promise->new (sub {
        my ($ok, $ng) = @_;
        http_post
            url => qq<http://$host/token>,
            header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
            params => {
              sk_context => 'tests', sk => $session->{sk},
              server => 'ssh',
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
          like $json->{access_token}->[0], qr{^ssh-dss \S+};
          unlike $json->{access_token}->[0], qr{PRIVATE KEY};
          like $json->{access_token}->[1], qr{PRIVATE KEY};
          isnt $json->{access_token}->[0], $json0->{access_token}->[0];
          isnt $json->{access_token}->[1], $json0->{access_token}->[1];
        } $c;
      });
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 9, name => '/keygen has account session', timeout => 60;

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
