use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Test::More;
use Test::X1;
use Promise;
use Promised::Flow;
use Web::UserAgent::Functions qw(http_post http_get);
use JSON::PS;
use Web::URL;
use Web::Transport::ConnectionClient;

my $wait = web_server;

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  my $url = Web::URL->parse_string ("http://$host");
  my $http = Web::Transport::ConnectionClient->new_from_url ($url);
  promised_cleanup {
    return $http->close->then (sub { done $c; undef $c });
  } $http->request (path => ['login'])->then (sub {
    my $res = $_[0];
    test {
      is $res->status, 405;
    } $c;
  });
} wait => $wait, n => 1, name => '/login GET';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  my $url = Web::URL->parse_string ("http://$host");
  my $http = Web::Transport::ConnectionClient->new_from_url ($url);
  promised_cleanup {
    return $http->close->then (sub { done $c; undef $c });
  } $http->request (path => ['login'], method => 'POST')->then (sub {
    my $res = $_[0];
    test {
      is $res->status, 401;
    } $c;
  });
} wait => $wait, n => 1, name => '/login no auth';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  my $url = Web::URL->parse_string ("http://$host");
  my $http = Web::Transport::ConnectionClient->new_from_url ($url);
  promised_cleanup {
    return $http->close->then (sub { done $c; undef $c });
  } $http->request (
    path => ['login'], method => 'POST',
    bearer => $c->received_data->{keys}->{'auth.bearer'},
    params => {sk_context => 'tests'},
  )->then (sub {
    my $res = $_[0];
    test {
      is $res->status, 400;
      my $json = json_bytes2perl $res->body_bytes;
      is $json->{reason}, 'Bad session';
    } $c;
  });
} wait => $wait, n => 2, name => '/login bad session';

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
            sk_context => 'not-tests',
            server => 'oauth1server',
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
      is $error->{reason}, 'Bad session';
    } $c;
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/login bad sk_context';

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
            sk_context => 'tests',
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
      is $error->{reason}, 'Bad |server|';
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
            sk_context => 'tests',
            server => 'oauth1server',
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
      my $auth = $c->received_data->{oauth1_auth_url};
      like $json->{authorization_url}, qr{^\Q$auth\E\?oauth_token=.+$};
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
