use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/modules/*/lib');
use Test::More;
use Test::X1;
use AnyEvent;
use Promised::Plackup;
use Web::UserAgent::Functions qw(http_get);

my $cv = AE::cv;
my $root_path = path (__FILE__)->parent->parent->parent;
my $plackup = Promised::Plackup->new;
$plackup->plackup ($root_path->child ('plackup'));
$plackup->set_option ('--app' => $root_path->child ('bin/server.psgi'));
$plackup->start->then (sub {
  $cv->send ({host => $plackup->get_host});
});

test {
  my $c = shift;
  my $host = $c->received_data->{host};
  http_get
      url => qq<http://$host/>,
      anyevent => 1,
      cb => sub {
        my $res = $_[1];
        test {
          is $res->code, 404; # XXX
          done $c;
          undef $c;
        } $c;
      };
} wait => $cv, n => 1, name => '/';

run_tests;

my $cv = AE::cv;
$plackup->stop->then (sub {
  $cv->send;
});
$cv->recv;
