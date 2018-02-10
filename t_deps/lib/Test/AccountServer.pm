package Test::AccountServer;
use strict;
use warnings;
use Path::Tiny;
use JSON::PS;
use Promise;
use Promised::Flow;
use Promised::File;
use Promised::Command;
use Promised::Plackup;
use Web::URL;
use Web::Transport::ConnectionClient;
use Test::DockerStack;

## Use of this module from outside of this repository is DEPRECATED.

{
  use Socket;
  sub _can_listen ($) {
    my $port = $_[0] or return 0;
    my $proto = getprotobyname ('tcp');
    socket (my $server, PF_INET, SOCK_STREAM, $proto) or die "socket: $!";
    setsockopt ($server, SOL_SOCKET, SO_REUSEADDR, pack ("l", 1))
        or die "setsockopt: $!";
    bind ($server, sockaddr_in($port, INADDR_ANY)) or return 0;
    listen ($server, SOMAXCONN) or return 0;
    close ($server);
    return 1;
  } # _can_listen
  sub _find_port () {
    my $used = {};
    for (1..10000) {
      my $port = int rand (5000 - 1024); # ephemeral ports
      next if $used->{$port};
      return $port if _can_listen $port;
      $used->{$port}++;
    }
    die "Listenable port not found";
  } # _find_port
}

my $RootPath = path (__FILE__)->parent->parent->parent->parent->absolute;

sub new ($;$) {
  my $opts = $_[1] || {};
  my $temp = File::Temp->newdir;
  return bless {
    servers => {},
    app_servers => $opts->{app_servers} || {},
    app_config => $opts->{app_config} || {},
    _temp => $temp, # files removed when destroyed
    config_path => path ($temp)->absolute,
  }, $_[0];
} # new

# OBSOLETE
sub set_web_host ($$) { }

sub set_mysql_server ($$) {
  $_[0]->{mysql_server} = $_[1];
} # set_mysql_server

# DEPRECATED
sub onbeforestart ($;$) {
  if (@_ > 1) {
    $_[0]->{onbeforestart} = $_[1];
  }
  return $_[0]->{onbeforestart} || sub { };
} # onbeforestart

sub _path ($$) {
  return $_[0]->{config_path}->child ($_[1]);
} # _path

sub _write_file ($$$) {
  my $self = $_[0];
  my $path = $self->_path ($_[1]);
  my $file = Promised::File->new_from_path ($path);
  return $file->write_byte_string ($_[2]);
} # _write_file

sub _write_json ($$$) {
  my $self = $_[0];
  return $self->_write_file ($_[1], perl2json_bytes $_[2]);
} # _write_json

sub _docker ($%) {
  my ($self, %args) = @_;
  my $storage_data = {};
  return Promise->all ([
    Promised::File->new_from_path ($self->_path ('minio_config'))->mkpath,
    Promised::File->new_from_path ($self->_path ('minio_data'))->mkpath,
  ])->then (sub {
    my $storage_port = _find_port;
    $storage_data->{aws4} = [undef, undef, undef, 's3'];
    $storage_data->{url_for_test} = Web::URL->parse_string
        ("http://0:$storage_port");
    $storage_data->{url_for_app} = Web::URL->parse_string
        ("http://0:$storage_port");
    $storage_data->{url_for_browser} = Web::URL->parse_string
        ("http://0:$storage_port");
    my $stack = Test::DockerStack->new ({
      services => {
        minio => {
          image => 'minio/minio',
          volumes => [
            $self->_path ('minio_config')->absolute . ':/config',
            $self->_path ('minio_data')->absolute . ':/data',
          ],
          user => "$<:$>",
          command => [
            'server',
            #'--address', "0.0.0.0:9000",
            '--config-dir', '/config',
            '/data'
          ],
          ports => [
            "$storage_port:9000",
          ],
        },
      },
    });
    $stack->propagate_signal (1);
    $stack->signal_before_destruction ('TERM');
    $stack->stack_name ($args{stack_name} // 'accounts-test-accountserver');
    $stack->use_fallback (1);
    my $out = '';
    $stack->logs (sub {
      my $v = $_[0];
      return unless defined $v;
      $v =~ s/^/docker: start: /gm;
      $v .= "\x0A" unless $v =~ /\x0A\z/;
      $out .= $v;
    });
    $self->{servers}->{docker} = {stop => sub { $stack->stop }};
    return $stack->start->catch (sub {
      warn $out;
      die $_[0];
    });
  })->then (sub {
    my $config_path = $self->_path ('minio_config')->child ('config.json');
    return promised_wait_until {
      return Promised::File->new_from_path ($config_path)->read_byte_string->then (sub {
        my $config = json_bytes2perl $_[0];
        $storage_data->{aws4}->[0] = $config->{credential}->{accessKey};
        $storage_data->{aws4}->[1] = $config->{credential}->{secretKey};
        $storage_data->{aws4}->[2] = $config->{region};
        return defined $storage_data->{aws4}->[0] &&
               defined $storage_data->{aws4}->[1] &&
               defined $storage_data->{aws4}->[2];
      })->catch (sub { return 0 });
    } timeout => 60*3;
  })->then (sub {
    my $client = Web::Transport::ConnectionClient->new_from_url
        ($storage_data->{url_for_test});
    $client->last_resort_timeout (1);
    return promised_cleanup {
      return $client->close;
    } promised_wait_until {
      return (promised_timeout {
        return $client->request (url => $storage_data->{url_for_test})->then (sub {
          return 0 if $_[0]->is_network_error;
          return 1;
        });
      } 1)->catch (sub {
        $client->abort;
        $client = Web::Transport::ConnectionClient->new_from_url
            ($storage_data->{url_for_test});
        return 0;
      });
    } timeout => 60, interval => 0.5;
  })->then (sub {
    $args{send_storage_data}->($storage_data);
  });
} # _docker

sub _storage_bucket ($%) {
  my ($self, %args) = @_;

  return $args{receive_storage_data}->then (sub {
    my $storage_data = $_[0];

    my $bucket_domain = rand . '.test';
    my $s3_url = Web::URL->parse_string
        ("/$bucket_domain/", $storage_data->{url_for_test});

    my $client = Web::Transport::ConnectionClient->new_from_url ($s3_url);
    return promised_cleanup {
      return $client->close;
    } $client->request (url => $s3_url, method => 'PUT', aws4 => $storage_data->{aws4})->then (sub {
      die $_[0] unless $_[0]->status == 200;
      my $body = qq{{
        "Version": "2012-10-17",
        "Statement": [{
          "Action": ["s3:GetObject"],
          "Effect": "Allow",
          "Principal": {"AWS": ["*"]},
          "Resource": ["arn:aws:s3:::$bucket_domain/*"],
          "Sid": ""
        }]
      }};
      return $client->request (url => Web::URL->parse_string ('./?policy', $s3_url), method => 'PUT', aws4 => $storage_data->{aws4}, body => $body);
    })->then (sub {
      die $_[0] unless $_[0]->is_success;

      my $data = {
        bucket_domain => $bucket_domain,
      };
      $data->{form_url} = Web::URL->parse_string
          ("/$bucket_domain/", $storage_data->{url_for_browser});
      $data->{image_root_url} = Web::URL->parse_string
          ("/$bucket_domain/", $storage_data->{url_for_browser});
      $args{send_storage_bucket_data}->($data);
    });
  });
} # _storage_bucket

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

sub _app ($%) {
  my ($self, %args) = @_;
  return Promise->all ([
    $args{receive_mysqld_data},
    $args{receive_storage_data},
    $args{receive_storage_bucket_data},
  ])->then (sub {
    my ($mysqld_data, $storage_data, $storage_bucket_data) = @{$_[0]};

    my $plackup = Promised::Plackup->new;
    $plackup->wd ($RootPath);
    $plackup->plackup ($RootPath->child ('plackup'));
    $plackup->set_option ('--server' => 'Twiggy::Prefork');
    $plackup->set_option ('--app' => $RootPath->child ('bin/server.psgi'));
    $plackup->envs->{APP_CONFIG} = $self->_path ('app_config.json');
    $plackup->start_timeout (60);

    my $data = {};
    my $servers = $self->{app_servers};
    my $config = $self->{app_config};
    $config->{servers_json_file} = 'app_servers.json';
    $config->{alt_dsns} = {master => {account => $mysqld_data->{dsn}}};
    #dsns => {account => $mysqld_data->{dsn}},

    $data->{keys}->{'auth.bearer'} = $config->{'auth.bearer'} = rand;

    $config->{s3_access_key_id} = $storage_data->{aws4}->[0];
    $config->{s3_secret_access_key} = $storage_data->{aws4}->[1];
    #"s3_sts_role_arn"
    $config->{s3_region} = $storage_data->{aws4}->[2];
    $config->{s3_bucket} = $storage_bucket_data->{bucket_domain};
    $config->{s3_form_url} = $storage_bucket_data->{form_url}->stringify;
    $config->{s3_image_url_prefix} = $storage_bucket_data->{image_root_url}->stringify;

    $config->{"s3_key_prefix.prefixed"} = "image/key/prefix";

    return Promise->resolve->then (sub {
      return $self->onbeforestart->($self,
                                    servers => $servers,
                                    config => $config,
                                    data => $data);
    })->then (sub {
      return Promise->all ([
        $self->_write_json ('app_servers.json', $servers),
        $self->_write_json ('app_config.json', $config),
      ]);
    })->then (sub {
      $self->{servers}->{app} = {stop => sub { $plackup->stop }};
      return $plackup->start;
    })->then (sub {
      $data->{host} = $plackup->get_host;
      $self->{web_port} = $plackup->get_port;
      $args{send_data}->($data);
    });
  });
} # _app

sub start ($) {
  my $self = $_[0];
  return Promise->resolve->then (sub {
    my ($r_mysqld_data, $s_mysqld_data) = promised_cv;
    my ($r_app_data, $s_app_data) = promised_cv;
    my ($r_storage_data, $s_storage_data) = promised_cv;
    my ($r_storage_bucket_data, $s_storage_bucket_data) = promised_cv;
    return Promise->all ([
      $self->_mysqld (
        send_data => $s_mysqld_data,
      ),
      $self->_docker (
        send_storage_data => $s_storage_data,
      ),
      $self->_storage_bucket (
        receive_storage_data => $r_storage_data,
        send_storage_bucket_data => $s_storage_bucket_data,
      ),
      $self->_app (
        receive_mysqld_data => $r_mysqld_data,
        receive_storage_data => $r_storage_data,
        receive_storage_bucket_data => $r_storage_bucket_data,
        send_data => $s_app_data,
      ),
    ])->then (sub {
      return $r_app_data;
    });
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

# DEPRECATED
sub get_web_port ($) {
  return $_[0]->{web_port};
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
