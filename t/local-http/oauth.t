use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Test::More;
use Test::X1;
use Promise;
use Web::UserAgent::Functions qw(http_get http_post);

my $wait = web_server;

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  http_get
      url => qq<http://$host/oauth>,
      anyevent => 1,
      cb => sub {
        my $res = $_[1];
        test {
          is $res->code, 200;
          my $cookie = $res->header ('Set-Cookie');
          like $cookie, qr{^sk=\w+; path=/; expires=.+; httponly};
          $cookie =~ /sk=(\w+)/;
          my $sk = $1;
          http_get
              url => qq<http://$host/oauth>,
              cookies => {sk => $sk},
              anyevent => 1,
              cb => sub {
                my $res = $_[1];
                test {
                  is $res->code, 200;
                  ok not $res->header ('Set-Cookie');
                  done $c;
                  undef $c;
                } $c;
              };
        } $c;
      };
} wait => $wait, n => 4, name => '/oauth';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  http_get
      url => qq<http://$host/oauth>,
      cookies => {sk => 'abaces'},
      anyevent => 1,
      cb => sub {
        my $res = $_[1];
        test {
          is $res->code, 200;
          my $cookie = $res->header ('Set-Cookie');
          like $cookie, qr{^sk=\w+; path=/; expires=.+; httponly};
          $cookie =~ /sk=(\w+)/;
          my $sk = $1;
          isnt $sk, 'abaces';
          done $c;
          undef $c;
        } $c;
      };
} wait => $wait, n => 3, name => '/oauth bad sk';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  http_get
      url => qq<http://$host/oauth/start?server=hatena>,
      anyevent => 1,
      cb => sub {
        my $res = $_[1];
        test {
          is $res->code, 405;
          done $c;
          undef $c;
        } $c;
      };
} wait => $wait, n => 1, name => '/oauth/start GET';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  http_post
      url => qq<http://$host/oauth/start>,
      params => {
        server => 'hatena',
      },
      max_redirect => 0,
      anyevent => 1,
      cb => sub {
        my $res = $_[1];
        test {
          is $res->code, 302;
          is $res->header ('Location'), qq{http://$host/oauth?server=hatena};
          done $c;
          undef $c;
        } $c;
      };
} wait => $wait, n => 2, name => '/oauth/start no sk';

sub session ($) {
  my $c = shift;
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    my $host = $c->received_data->{host};
    http_get
        url => qq<http://$host/oauth>,
        anyevent => 1,
        cb => sub {
          my $res = $_[1];
          my $cookie = $res->header ('Set-Cookie') // '';
          if ($cookie =~ /^sk=(\w+)/) {
            $ok->($1);
          } else {
            $ng->();
          }
        };
  });
} # session

## Need access to www.hatena.ne.jp
test {
  my $c = shift;
  session ($c)->then (sub {
    my $sk = $_[0];
    my $host = $c->received_data->{host};
    http_post
        url => qq<http://$host/oauth/start>,
        cookies => {
          sk => $sk,
        },
        params => {
          server => 'hatena',
        },
        max_redirect => 0,
        anyevent => 1,
        cb => sub {
          my $res = $_[1];
          test {
            is $res->code, 302;
            like $res->header ('Location'), qr{^https://www.hatena.ne.jp/oauth/authorize\?oauth_token=.+$};
            done $c;
            undef $c;
          } $c;
        };
  });
} wait => $wait, n => 2, name => '/oauth/start';

test {
  my $c = shift;
  session ($c)->then (sub {
    my $sk = $_[0];
    my $host = $c->received_data->{host};
    http_post
        url => qq<http://$host/oauth/start>,
        cookies => {
          sk => $sk,
        },
        params => {
          server => 'hoge',
        },
        max_redirect => 0,
        anyevent => 1,
        cb => sub {
          my $res = $_[1];
          test {
            is $res->code, 404;
            done $c;
            undef $c;
          } $c;
        };
  });
} wait => $wait, n => 1, name => '/oauth/start unknown server';

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  http_post
      url => qq<http://$host/oauth/cb>,
      params => {
        server => 'hatena',
        state => 'hoge',
      },
      max_redirect => 0,
      anyevent => 1,
      cb => sub {
        my $res = $_[1];
        test {
          is $res->code, 302;
          is $res->header ('Location'), qq{http://$host/oauth?server=hatena};
          done $c;
          undef $c;
        } $c;
      };
} wait => $wait, n => 2, name => '/oauth/cb not in session';

test {
  my $c = shift;
  session ($c)->then (sub {
    my $sk = $_[0];
    my $host = $c->received_data->{host};
    http_post
        url => qq<http://$host/oauth/cb>,
        cookies => {
          sk => $sk,
        },
        params => {
          server => 'hatena',
          state => 'hoge',
        },
        max_redirect => 0,
        anyevent => 1,
        cb => sub {
          my $res = $_[1];
          test {
            is $res->code, 400;
            done $c;
            undef $c;
          } $c;
        };
  });
} wait => $wait, n => 1, name => '/oauth/cb bad context';

test {
  my $c = shift;
  session ($c)->then (sub {
    my $sk = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      my $host = $c->received_data->{host};
      http_post
          url => qq<http://$host/oauth/start>,
          cookies => {
            sk => $sk,
          },
          params => {
            server => 'hatena',
          },
          max_redirect => 0,
          anyevent => 1,
          cb => sub {
            my $res = $_[1];
            $ok->();
          };
    })->then (sub {
      my $host = $c->received_data->{host};
      http_post
          url => qq<http://$host/oauth/cb>,
          cookies => {
            sk => $sk,
          },
          params => {
            server => 'hatena',
            state => 'hoge',
          },
          max_redirect => 0,
          anyevent => 1,
          cb => sub {
            my $res = $_[1];
            test {
              is $res->code, 400;
              done $c;
              undef $c;
            } $c;
          };
    });
  });
} wait => $wait, n => 1, name => '/oauth/cb bad state';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
