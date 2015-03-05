package Tests;
use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/modules/*/lib');
use File::Temp;
use AnyEvent;
use Promise;
use Promised::File;
use Promised::Plackup;
use Promised::Mysqld;
use Promised::Docker::WebDriver;
use JSON::PS;

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

my $MySQLServer;
my $HTTPServer;
my $Browsers = {};

my $root_path = path (__FILE__)->parent->parent->parent;

sub db_sqls () {
  my $file = Promised::File->new_from_path
      ($root_path->child ('db/account.sql'));
  return $file->read_byte_string->then (sub {
    return [split /;/, $_[0]];
  });
} # db_sqls

push @EXPORT, qw(web_server);
sub web_server (;$) {
  my $web_host = $_[0];
  my $cv = AE::cv;
  $MySQLServer = Promised::Mysqld->new;
  $MySQLServer->start->then (sub {
    my $dsn = $MySQLServer->get_dsn_string (dbname => 'account_test');
    $MySQLServer->{_temp} = my $temp = File::Temp->new;
    my $temp_path = path ($temp)->absolute;
    my $temp_file = Promised::File->new_from_path ($temp_path);
    $HTTPServer = Promised::Plackup->new;
    $HTTPServer->envs->{APP_CONFIG} = $temp_path;
    return Promise->all ([
      db_sqls->then (sub {
        $MySQLServer->create_db_and_execute_sqls (account_test => $_[0]);
      }),
      $temp_file->write_byte_string (perl2json_bytes {
        alt_dsns => {master => {account => $dsn}},
        dsns => {account => $dsn},
      }),
    ]);
  })->then (sub {
    $HTTPServer->plackup ($root_path->child ('plackup'));
    $HTTPServer->set_option ('--host' => $web_host) if defined $web_host;
    $HTTPServer->set_option ('--app' => $root_path->child ('bin/server.psgi'));
    return $HTTPServer->start;
  })->then (sub {
    $cv->send ({host => $HTTPServer->get_host});
  });
  return $cv;
} # web_server

push @EXPORT, qw(web_server_and_driver);
sub web_server_and_driver () {
  my $cv = AE::cv;
  my $cv1 = web_server ('0.0.0.0'); # XXX
  $cv1->cb (sub {
    my $data = $_[0]->recv;
    my $wd = $Browsers->{chrome} = Promised::Docker::WebDriver->chrome;
    $wd->start->then (sub {
      $data->{host_for_browser} = $wd->get_docker_host_hostname_for_container . ':' . $HTTPServer->get_port;
      $data->{wd_url} = $wd->get_url_prefix;
      $cv->send ($data);
    });
  });
  return $cv;
} # web_server_and_driver

push @EXPORT, qw(stop_web_server);
sub stop_web_server () {
  my $cv = AE::cv;
  $cv->begin;
  $cv->begin;
  $HTTPServer->stop->then (sub {
    $cv->end;
  });
  $cv->begin;
  $MySQLServer->stop->then (sub {
    $cv->end;
  });
  for (values %$Browsers) {
    $cv->begin;
    $_->stop->then (sub { $cv->end });
  }
  $cv->end;
  $cv->recv;
} # stop_web_server

push @EXPORT, qw(stop_web_server_and_driver);
*stop_web_server_and_driver = \&stop_web_server;

1;
