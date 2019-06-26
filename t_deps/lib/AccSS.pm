package AccSS;
use strict;
use warnings;
use Path::Tiny;
use Promise;
use ServerSet;

my $RootPath = path (__FILE__)->parent->parent->parent->absolute;

sub run ($%) {
  ## Arguments:
  ##   app_port       The port of the main application server.  Optional.
  ##   data_root_path Path::Tiny of the root of the server's data files.  A
  ##                  temporary directory (removed after shutdown) if omitted.
  ##   mysqld_database_name_suffix Name's suffix used in mysql database.
  ##                  Optional.
  ##   signal         AbortSignal canceling the server set.  Optional.
  my $class = shift;
  return ServerSet->run ({
    proxy => {
      handler => 'ServerSet::ReverseProxyHandler',
      prepare => sub {
        my ($handler, $self, $args, $data) = @_;
        return {
          client_urls => [],
        };
      }, # prepare
    }, # proxy
    mysqld => {
      handler => 'ServerSet::MySQLServerHandler',
    },
    storage => {
      handler => 'ServerSet::MinioHandler',
    },
    app_config => {
      requires => ['mysqld', 'storage'],
      keys => {
        app_bearer => 'key',
      },
      start => sub ($$%) {
        my ($handler, $self, %args) = @_;
        my $data = {};
        return Promise->all ([
          $self->read_json (\($args{app_config_path})),
          $self->read_json (\($args{app_servers_path})),
          $args{receive_storage_data},
          $args{receive_mysqld_data},
        ])->then (sub {
          my ($config, $servers, $storage_data, $mysqld_data) = @{$_[0]};
          $data->{config} = $config;

          if ($args{use_xs_servers}) {
            my $cid = $self->key ('xs_client_id');
            my $csc = $self->key ('xs_client_secret');
            $config->{"oauth1server.client_id"} = $cid.".oauth1";
            $config->{"oauth1server.client_secret"} = $csc.".oauth1";
            $config->{"oauth2server.client_id"} = $cid.".oauth2";
            $config->{"oauth2server.client_secret"} = $csc.".oauth2";
            $config->{"oauth2server_refresh.client_id"} = $cid.".oauth2";
            $config->{"oauth2server_refresh.client_secret"} = $csc.".oauth2";
            $config->{"oauth1server.client_id.sk2"} = $cid.".oauth1.SK2";
            $config->{"oauth1server.client_secret.sk2"} = $csc.".oauth1.SK2";
            $config->{"oauth2server.client_id.sk2"} = $cid.".oauth2.SK2";
            $config->{"oauth2server.client_secret.sk2"} = $csc.".oauth2.SK2";
          }
          
          #XXX
          #$data->{oauth1_auth_url} = sprintf q<http://%s/oauth1/authorize>, $host;
          #$data->{oauth2_auth_url} = sprintf q<http://%s/oauth2/authorize>, $host;

          $data->{app_docker_image} = $args{app_docker_image}; # or undef
          my $use_docker = defined $data->{app_docker_image};

          $config->{'auth.bearer'} = $self->key ('app_bearer');

          my $dsn_key = $use_docker ? 'docker_dsn' : 'local_dsn';
          my $dsn = $mysqld_data->{$dsn_key}->{accounts};
          $config->{alt_dsns} = {master => {account => $dsn}};
          #dsns => {account => $dsn},

          $config->{s3_access_key_id} = $storage_data->{aws4}->[0];
          $config->{s3_secret_access_key} = $storage_data->{aws4}->[1];
          #"s3_sts_role_arn"
          $config->{s3_region} = $storage_data->{aws4}->[2];
          $config->{s3_bucket} = $storage_data->{bucket_domain};
          $config->{s3_form_url} = $storage_data->{form_client_url}->stringify;
          $config->{s3_image_url_prefix} = $storage_data->{file_root_client_url}->stringify;
          $config->{"s3_key_prefix.prefixed"} = "image/key/prefix";

          $data->{envs} = my $envs = {};
          if ($use_docker) {
            $self->set_docker_envs ('proxy' => $envs);
          } else {
            $self->set_local_envs ('proxy' => $envs);
          }

          $config->{servers_json_file} = 'app-servers.json';
          $data->{config_path} = $self->path ('app-config.json');
          return Promise->all ([
            $self->write_json ('app-config.json', $config),
            $self->write_json ('app-servers.json', $servers),
          ]);
        })->then (sub {
          return [$data, undef];
        });
      },
    }, # app_envs
    app => {
      handler => 'ServerSet::SarzeProcessHandler',
      requires => ['app_config', 'proxy'],
      prepare => sub {
        my ($handler, $self, $args, $data) = @_;
        return Promise->resolve ($args->{receive_app_config_data})->then (sub {
          my $config_data = shift;
          return {
            envs => {
              %{$config_data->{envs}},
              APP_CONFIG => $config_data->{config_path},
            },
            command => [
              $RootPath->child ('perl'),
              $RootPath->child ('bin/sarze.pl'),
            ],
            local_url => $self->local_url ('app'),
          };
        });
      }, # prepare
    }, # app
    app_docker => {
      handler => 'ServerSet::DockerHandler',
      requires => ['app_config', 'proxy'],
      prepare => sub {
        my ($handler, $self, $args, $data) = @_;
        return Promise->resolve ($args->{receive_app_config_data})->then (sub {
          my $config_data = shift;
          my $net_host = $args->{docker_net_host};
          my $port = $self->local_url ('app')->port; # default: 8080
          return {
            image => $config_data->{app_docker_image},
            volumes => [
              $config_data->{config_path}->absolute . ':/app-config.json',
            ],
            net_host => $net_host,
            ports => ($net_host ? undef : [
              $self->local_url ('app')->hostport . ":" . $port,
            ]),
            environment => {
              %{$config_data->{envs}},
              PORT => $port,
              APP_CONFIG => '/app-config.json',
            },
            command => ['/server'],
          };
        });
      }, # prepare
      wait => sub {
        my ($handler, $self, $args, $data, $signal) = @_;
        return $self->wait_for_http (
          $self->local_url ('app'),
          signal => $signal, name => 'wait for app',
          check => sub {
            return $handler->check_running;
          },
        );
      }, # wait
    }, # app_docker
    xs => {
      handler => 'ServerSet::SarzeProcessHandler',
      keys => {
        xs_client_id => 'key',
        xs_client_secret => 'key',
      },
      prepare => sub {
        my ($handler, $self, $args, $data) = @_;
        my $name = rand;

        #XXX
        #$data->{oauth_server_account_name} = $OAuthServer->envs->{ACCOUNT_NAME};
        #$data->{oauth_server_account_email} = $OAuthServer->envs->{ACCOUNT_EMAIL};
        
        return {
          envs => {
            CLIENT_ID => $self->key ('xs_client_id'),
            CLIENT_SECRET => $self->key ('xs_client_secret'),
            ACCOUNT_ID => $name,
            ACCOUNT_NAME => $name . '-san',
            ACCOUNT_EMAIL => $name . '@test',
          },
          command => [
            $RootPath->child ('perl'),
            '-e', (sprintf q{
              use Sarze;
              Sarze->run (
                hostports => [[shift, shift]],
                psgi_file_name => shift,
                max_worker_count => 1,
              )->to_cv->recv;
            },
              $self->local_url ('xs')->host->to_ascii,
              $self->local_url ('xs')->port,
              $RootPath->child ('t_deps/bin/xs.psgi'),
            ),
          ],
          local_url => $self->local_url ('xs'),
        };
      }, # prepare
    }, # xs
    cs => {
      handler => 'ServerSet::SarzeProcessHandler',
      prepare => sub {
        my ($handler, $self, $args, $data) = @_;
        return {
          envs => {
            API_TOKEN => $self->key ('app_bearer'),
            API_HOST => $self->client_url ('app')->host->to_ascii,
          },
          command => [
            $RootPath->child ('perl'),
            '-e', (sprintf q{
              use Sarze;
              Sarze->run (
                hostports => [[shift, shift]],
                psgi_file_name => shift,
                max_worker_count => 1,
              )->to_cv->recv;
            },
              $self->local_url ('cs')->host->to_ascii,
              $self->local_url ('cs')->port,
              $RootPath->child ('t_deps/bin/cs.psgi'),
            ),
          ],
          local_url => $self->local_url ('cs'),
        };
      }, # prepare
    }, # cs
    _ => {
      requires => ['app_config'],
      start => sub {
        my ($handler, $self, %args) = @_;
        my $data = {};

        ## app_client_url Web::URL of the main application server for clients.
        ## app_local_url Web::URL the main application server is listening.
        ## local_envs   Environment variables setting proxy for /this/ host.
        
        $data->{app_local_url} = $self->local_url ('app');
        $data->{app_client_url} = $self->client_url ('app');
        $data->{app_bearer} = $self->key ('app_bearer');
        $self->set_local_envs ('proxy', $data->{local_envs} = {});

        return [$data, undef];
      },
    }, # _
  }, sub {
    my ($ss, $args) = @_;
    my $result = {};

    $result->{exposed} = {
      proxy => [$args->{proxy_host}, $args->{proxy_port}],
      app => [$args->{app_host}, $args->{app_port}],
    };

    my $app_docker_image = $args->{app_docker_image} // '';
    $result->{server_params} = {
      proxy => {
      },
      mysqld => {
        databases => {
          accounts => $RootPath->child ('db/account.sql'),
        },
        database_name_suffix => $args->{mysqld_database_name_suffix},
      },
      storage => {
        docker_net_host => $args->{docker_net_host},
        no_set_uid => $args->{no_set_uid},
        public_prefixes => [
        ],
      },
      app_config => {
        app_config_path => $args->{dont_run_xs} ? undef : $RootPath->child ('t_deps/app-config.json'),
        app_servers_path => $args->{dont_run_xs} ? undef : $RootPath->child ('t_deps/app-servers.json'),
        app_docker_image => $app_docker_image || undef,
        use_xs_servers => ! $args->{dont_run_xs},
      },
      app => {
        disabled => !! $app_docker_image,
      },
      app_docker => {
        disabled => ! $app_docker_image,
        docker_net_host => $args->{docker_net_host},
      },
      xs => {
        disabled => $args->{dont_run_xs},
      },
      cs => {
        disabled => $args->{dont_run_xs},
      },
      _ => {},
    }; # $result->{server_params}

    return $result;
  }, @_);
} # run

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
