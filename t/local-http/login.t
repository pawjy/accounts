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
        url => qq<http://$host/login>,
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
      done $c;
      undef $c;
    } $c;
  });
} wait => $wait, n => 1, name => '/login GET';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post
        url => qq<http://$host/login>,
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
      done $c;
      undef $c;
    } $c;
  });
} wait => $wait, n => 1, name => '/login no auth';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post
        url => qq<http://$host/login>,
        header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
        anyevent => 1,
        max_redirect => 0,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } elsif ($res->code == 400) {
            $ng->(json_bytes2perl $res->content);
          } else {
            $ng->($res->code);
          }
        };
  })->then (sub { test { ok 0 } $c }, sub {
    my $error = $_[0];
    test {
      is $error->{reason}, 'Bad session';
      done $c;
      undef $c;
    } $c;
  });
} wait => $wait, n => 1, name => '/login bad session';

sub session ($) {
  my ($c) = @_;
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    my $host = $c->received_data->{host};
    http_post
        url => qq<http://$host/session>,
        header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
        anyevent => 1,
        max_redirect => 0,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } elsif ($res->code == 400) {
            $ng->(json_bytes2perl $res->content);
          } else {
            $ng->($res->code);
          }
        };
  });
} # session

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  session ($c)->then (sub {
    my $session = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/login>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {
            sk => $session->{sk},
            server => 'xaa',
            callback_url => 'http://haoa/',
          },
          anyevent => 1,
          max_redirect => 0,
          cb => sub {
            my $res = $_[1];
            if ($res->code == 200) {
              $ok->(json_bytes2perl $res->content);
            } elsif ($res->code == 400) {
              $ng->(json_bytes2perl $res->content);
            } else {
              $ng->($res->code);
            }
          };
    });
  })->then (sub { test { ok 0 } $c }, sub {
    my $error = $_[0];
    test {
      is $error, undef;
    } $c;
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/login bad server';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  session ($c)->then (sub {
    my $session = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      http_post
          url => qq<http://$host/login>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
          params => {
            sk => $session->{sk},
            server => 'hatena',
            callback_url => 'http://haoa/',
          },
          anyevent => 1,
          max_redirect => 0,
          cb => sub {
            my $res = $_[1];
            if ($res->code == 200) {
              $ok->(json_bytes2perl $res->content);
            } elsif ($res->code == 400) {
              $ng->(json_bytes2perl $res->content);
            } else {
              $ng->($res->code);
            }
          };
    });
  })->then (sub {
    my $json = $_[0];
    test {
      like $json->{authorization_url}, qr{^https://www.hatena.ne.jp/oauth/authorize\?oauth_token=.+$};
    } $c;
  }, sub { test { ok 0 } $c })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/login';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
