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
use MIME::Base64;
use JSON::PS;
use Web::UserAgent::Functions qw(http_get http_post);

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
my $AppServer;
my $Browsers = {};

my $root_path = path (__FILE__)->parent->parent->parent;
#my $config_keys_path = $root_path->child ('local/keys/test/config-keys.json');
#my $config_keys_file = Promised::File->new_from_path ($config_keys_path);

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
  my $keys;
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
      #$config_keys_file->read_byte_string->then (sub {
      #  $keys = json_bytes2perl $_[0];
      do {
        $keys = {
          "auth.bearer" => rand,
        };
        $temp_file->write_byte_string (perl2json_bytes {
          %$keys,
          alt_dsns => {master => {account => $dsn}},
          #dsns => {account => $dsn},
        });
      #}),
      },
    ]);
  })->then (sub {
    $HTTPServer->plackup ($root_path->child ('plackup'));
    $HTTPServer->set_option ('--host' => $web_host) if defined $web_host;
    $HTTPServer->set_option ('--app' => $root_path->child ('bin/server.psgi'));
    return $HTTPServer->start;
  })->then (sub {
    for my $key (keys %$keys) {
      my $value = $keys->{$key};
      if (defined $value and ref $value eq 'ARRAY' and
          defined $value->[0] and $value->[0] eq 'Base64') {
        $keys->{$key} = decode_base64 $value->[1];
      }
    }
    $cv->send ({host => $HTTPServer->get_host, keys => $keys});
  });
  return $cv;
} # web_server

sub app_server ($$$) {
  my ($app_hostname, $api_token, $api_host) = @_;
  $AppServer = Promised::Plackup->new;
  $AppServer->plackup ($root_path->child ('plackup'));
  $AppServer->set_option ('--host' => $app_hostname);
  $AppServer->envs->{API_TOKEN} = $api_token;
  $AppServer->envs->{API_HOST} = $api_host;
  $AppServer->set_app_code (q{
    use Wanage::HTTP;
    use Wanage::URL;
    use Web::UserAgent::Functions qw(http_post);
    use JSON::PS;
    use MIME::Base64;
    my $api_token = $ENV{API_TOKEN};
    my $host = $ENV{API_HOST};
    sub {
      my $env = shift;
      my $http = Wanage::HTTP->new_from_psgi_env ($env);
      my $path = $http->url->{path};
      if ($path eq '/start') {
        my (undef, $res) = http_post
            url => qq<http://$host/session>,
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              sk => $http->request_cookies->{sk},
              sk_context => 'app.cookie',
            };
        my $json = json_bytes2perl $res->content;
        $http->set_response_cookie (sk => $json->{sk}, expires => $json->{sk_expires}, path => q</>, httponly => 0, secure => 0)
            if $json->{set_sk};

        my $cb_url = $http->url->resolve_string ('/cb?')->stringify;
        $cb_url .= '&bad_state=1' if $http->query_params->{bad_state};
        $cb_url .= '&bad_code=1' if $http->query_params->{bad_code};
        my (undef, $res) = http_post
            url => qq<http://$host/login?app_data=> . (percent_encode_b $http->query_params->{app_data}->[0] // ''),
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              sk => $json->{sk},
              sk_context => 'app.cookie',
              server => 'hatena',
              callback_url => $cb_url,
            };
        my $json = json_bytes2perl $res->content;
        $http->set_status (302);
        my $url = $json->{authorization_url};
        $http->set_response_header (Location => $url);
      } elsif ($path eq '/cb') {
        my (undef, $res) = http_post
            url => qq<http://$host/cb>,
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              sk => $http->request_cookies->{sk},
              sk_context => 'app.cookie',
              oauth_token => $http->query_params->{oauth_token},
              oauth_verifier => $http->query_params->{bad_code} ? 'bee' : $http->query_params->{oauth_verifier},
              code => $http->query_params->{code},
              state => $http->query_params->{bad_state} ? 'aaa' : $http->query_params->{state},
            };
        if ($res->code == 200) {
          my $json = json_bytes2perl $res->content;
          $http->set_status (200);
          $http->send_response_body_as_text (encode_base64 perl2json_bytes {status => $res->code, app_data => $json->{app_data}});
        } else {
          $http->set_status (400);
          $http->send_response_body_as_text ($res->code);
        }
      } elsif ($path eq '/info') {
        my (undef, $res) = http_post
            url => qq<http://$host/info>,
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              sk => $http->request_cookies->{sk},
              sk_context => 'app.cookie',
            };
        $http->send_response_body_as_ref (\($res->content));
      } elsif ($path eq '/profiles') {
        my (undef, $res) = http_post
            url => qq<http://$host/profiles>,
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              account_id => $http->query_params->{account_id},
            };
        $http->send_response_body_as_ref (\($res->content));
      } elsif ($path eq '/token') {
        my (undef, $res) = http_post
            url => qq<http://$host/token>,
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              sk => $http->request_cookies->{sk},
              sk_context => 'app.cookie',
              server => $http->query_params->{server},
            };
        $http->send_response_body_as_ref (\($res->content));
      }
      $http->close_response_body;
      return $http->send_response;
    };
  });
  return $AppServer->start;
} # app_server

push @EXPORT, qw(web_server_and_driver);
sub web_server_and_driver () {
  $ENV{TEST_MAX_CONCUR} ||= 1;
  my $cv = AE::cv;
  my $cv1 = web_server ('127.0.0.1');
  $cv1->cb (sub {
    my $data = $_[0]->recv;
    my $wd = $Browsers->{chrome} = Promised::Docker::WebDriver->chrome;
    $wd->start->then (sub {
      $data->{wd_url} = $wd->get_url_prefix;
      my $api_token = $data->{keys}->{'auth.bearer'};
      my $api_host = '127.0.0.1:' . $HTTPServer->get_port;
      return app_server ('0.0.0.0', $api_token, $api_host)->then (sub {
        $data->{host_for_browser} = $wd->get_docker_host_hostname_for_container . ':' . $AppServer->get_port;
        $cv->send ($data);
      });
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
  if (defined $AppServer) {
    $cv->begin;
    $AppServer->stop->then (sub { $cv->end });
  }
  $cv->recv;
} # stop_web_server

push @EXPORT, qw(stop_web_server_and_driver);
*stop_web_server_and_driver = \&stop_web_server;

push @EXPORT, qw(session);
sub session ($;%) {
  my ($c, %args) = @_;
  my $p = Promise->new (sub {
    my ($ok, $ng) = @_;
    my $host = $c->received_data->{host};
    http_post
        url => qq<http://$host/session>,
        header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
        params => {sk_context => 'tests'},
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

  if ($args{account}) {
    $p = $p->then (sub {
      my $session = $_[0];
      return Promise->new (sub {
        my ($ok, $ng) = @_;
        my $host = $c->received_data->{host};
        http_post
            url => qq<http://$host/create>,
            header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
            params => {sk_context => 'tests', sk => $session->{sk}},
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
      })->then (sub {
        my $account = $_[0];
        return {%$session, %$account};
      });
    });
  }

  return $p;
} # session

1;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
