package Test::AccountServer;
use strict;
use warnings;
use Path::Tiny;
use JSON::PS;
use Promise;
use Promised::File;
use Promised::Plackup;

my $RootPath = path (__FILE__)->parent->parent->parent->parent->absolute;

sub new ($) {
  return bless {}, $_[0];
} # new

sub set_mysql_server ($$) {
  $_[0]->{mysql_server} = $_[1];
} # set_mysql_server

sub set_web_host ($$) {
  $_[0]->{web_host} = $_[1];
} # set_web_host

sub onbeforestart ($;$) {
  if (@_ > 1) {
    $_[0]->{onbeforestart} = $_[1];
  }
  return $_[0]->{onbeforestart} || sub { };
} # onbeforestart

sub start ($) {
  my $self = $_[0];

  my $p = Promise->resolve;

  my $mysql = $self->{mysql_server};
  unless (defined $mysql) {
    require Promised::Mysqld;
    $self->{mysql} = $mysql = Promised::Mysqld->new;
    $p = $p->then (sub { return $mysql->start });
  }

  my $data = {};
  $p = $p->then (sub {
    my $dsn = $mysql->get_dsn_string (dbname => 'account_test');

    $self->{_temp} = my $temp = File::Temp->newdir;
    my $temp_dir_path = path ($temp)->absolute;
    my $temp_path = $temp_dir_path->child ('file');
    my $temp_file = Promised::File->new_from_path ($temp_path);

    $self->{http} = Promised::Plackup->new;
    $self->{http}->set_option ('--server' => 'Twiggy::Prefork');
    $self->{http}->envs->{APP_CONFIG} = $temp_path;

    my $servers = {};
    my $servers_json_path = $temp_dir_path->child ('servers.json');

    my $bearer = rand;
    $data->{keys} = {'auth.bearer' => $bearer};

    my $config = {
      "auth.bearer" => $bearer,
      servers_json_file => $servers_json_path,
      alt_dsns => {master => {account => $dsn}},
      #dsns => {account => $dsn},
    }; # $config

    return Promise->all ([
      Promised::File->new_from_path ($RootPath->child ('db/account.sql'))->read_byte_string->then (sub {
        return [split /;/, $_[0]];
      })->then (sub {
        return $mysql->create_db_and_execute_sqls (account_test => $_[0]);
      }),
      $self->onbeforestart->($self,
                             servers => $servers,
                             config => $config,
                             data => $data),
    ])->then (sub {
      return Promise->all ([
        Promised::File->new_from_path ($servers_json_path)->write_byte_string (perl2json_bytes $servers),
        $temp_file->write_byte_string (perl2json_bytes $config),
      ]);
    });
  })->then (sub {
    $self->{http}->wd ($RootPath);
    $self->{http}->plackup ($RootPath->child ('plackup'));
    my $web_host = $self->{web_host};
    $self->{http}->set_option ('--host' => $web_host) if defined $web_host;
    $self->{http}->set_option ('--app' => $RootPath->child ('bin/server.psgi'));
    $self->{http}->start_timeout (60);
    return $self->{http}->start;
  })->then (sub {
    $data->{host} = $self->{http}->get_host;
    return $data;
  });
} # start

sub stop ($) {
  my $self = $_[0];
  return Promise->all ([
    ($self->{mysql} ? $self->{mysql}->stop : undef),
    ($self->{http} ? $self->{http}->stop : undef),
  ]);
} # stop

sub get_web_port ($) {
  return $_[0]->{http}->get_port;
} # get_web_port

1;
