package Tests;
use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/modules/*/lib');
use AnyEvent;
use Promised::Plackup;

our @EXPORT;

sub import ($;@) {
  my $from_class = shift;
  my ($to_class, $file, $line) = caller;
  no strict 'refs';
  for (@_ ? @_ : @{$from_class . '::EXPORT'}) {
    my $code = $from_class->can ($_)
        or die qq{"$_" is not exported by the $from_class module at $file line $line};
    *{$to_class . '::' . $_} = $code;
  }
} # import

my $HTTPServer;

push @EXPORT, qw(web_server);
sub web_server () {
  my $cv = AE::cv;
  my $root_path = path (__FILE__)->parent->parent->parent;
  $HTTPServer = Promised::Plackup->new;
  $HTTPServer->plackup ($root_path->child ('plackup'));
  $HTTPServer->set_option ('--app' => $root_path->child ('bin/server.psgi'));
  $HTTPServer->start->then (sub {
    $cv->send ({host => $HTTPServer->get_host});
  });
  return $cv;
} # web_server

push @EXPORT, qw(stop_web_server);
sub stop_web_server () {
  my $cv = AE::cv;
  $HTTPServer->stop->then (sub {
    $cv->send;
  });
  $cv->recv;
} # stop_web_server

1;
