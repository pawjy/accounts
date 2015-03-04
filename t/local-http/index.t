use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Test::More;
use Test::X1;
use Web::UserAgent::Functions qw(http_get);

my $wait = web_server;

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  http_get
      url => qq<http://$host/>,
      anyevent => 1,
      cb => sub {
        my $res = $_[1];
        test {
          is $res->code, 200;
          done $c;
          undef $c;
        } $c;
      };
} wait => $wait, n => 1, name => '/';

run_tests;
stop_web_server;
