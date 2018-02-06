package Test::AccountServer;
use strict;
use warnings;
use Path::Tiny;
use JSON::PS;
use Promise;
use Promised::Flow;
use Promised::File;
use Promised::Plackup;

my $RootPath = path (__FILE__)->parent->parent->parent->parent->absolute;

sub new ($) {
  my $temp = File::Temp->newdir;
  return bless {
    servers => {},
    _temp => $temp, # files removed when destroyed
    config_path => path ($temp)->absolute,
  }, $_[0];
} # new

sub _path ($$) {
  return $_[0]->{config_path}->child ($_[1]);
} # _path

# OBSOLETE
sub set_web_host ($$) { }

sub set_mysql_server ($$) {
  $_[0]->{mysql_server} = $_[1];
} # set_mysql_server

sub onbeforestart ($;$) {
  if (@_ > 1) {
    $_[0]->{onbeforestart} = $_[1];
  }
  return $_[0]->{onbeforestart} || sub { };
} # onbeforestart

sub _mysqld ($%) {
  my ($self, %args) = @_;
  return Promise->resolve->then (sub {
    my $mysql = $self->{mysql_server};
    return $mysql if defined $mysql;
    
    require Promised::Mysqld;
    $mysql = Promised::Mysqld->new;
    $self->{servers}->{mysqld} = {stop => sub { $mysql->stop }};
    return $mysql->start->then (sub { return $mysql });
  })->then (sub {
    my $mysql = $_[0];
    return Promised::File->new_from_path ($RootPath->child ('db/account.sql'))->read_byte_string->then (sub {
      return [split /;/, $_[0]];
    })->then (sub {
      return $mysql->create_db_and_execute_sqls (account_test => $_[0]);
    })->then (sub {
      my $dsn = $mysql->get_dsn_string (dbname => 'account_test');
      $args{send_data}->({dsn => $dsn});
    });
  });
} # _mysqld

sub start ($) {
  my $self = $_[0];

  my $p = Promise->resolve;

  my ($r_mysqld_data, $s_mysqld_data) = promised_cv;
  $p = $p->then (sub { return $self->_mysqld (
    send_data => $s_mysqld_data,
  ) });

  my $data = {};
  $p = $p->then (sub {
    return $r_mysqld_data;
  })->then (sub {
    my $mysqld_data = $_[0];

    my $temp_path = $self->_path ('app_config.json');
    my $temp_file = Promised::File->new_from_path ($temp_path);

    $self->{http} = Promised::Plackup->new;
    $self->{http}->set_option ('--server' => 'Twiggy::Prefork');
    $self->{http}->envs->{APP_CONFIG} = $temp_path;

    my $servers = {};
    my $servers_json_path = $self->_path ('app_servers.json');

    my $bearer = rand;
    $data->{keys} = {'auth.bearer' => $bearer};

    my $config = {
      "auth.bearer" => $bearer,
      servers_json_file => 'app_servers.json',
      alt_dsns => {master => {account => $mysqld_data->{dsn}}},
      #dsns => {account => $mysqld_data->{dsn}},
    }; # $config

    return Promise->all ([
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
    $self->{http}->set_option ('--app' => $RootPath->child ('bin/server.psgi'));
    $self->{http}->start_timeout (60);
    $self->{servers}->{http} = {stop => sub { $self->{http}->stop }};
    return $self->{http}->start;
  })->then (sub {
    $data->{host} = $self->{http}->get_host;
    return $data;
  });
} # start

sub stop ($) {
  my $self = $_[0];
  return promised_cleanup {
    delete $self->{servers};
  } Promise->all ([ map {
    my $key = $_;
    $self->{servers}->{$key}->{stop}->()->catch (sub {
      warn "$key: Failed to stop: $_[0]\n";
    });
  } keys %{$self->{servers}} ]);
} # stop

sub get_web_port ($) {
  return $_[0]->{servers}->{http}->get_port;
} # get_web_port

1;

=head1 LICENSE

Copyright 2015-2018 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You does not have received a copy of the GNU Affero General Public
License along with this program, see <http://www.gnu.org/licenses/>.

=cut
