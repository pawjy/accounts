package Tests;
use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/modules/*/lib');
use File::Temp;
use AnyEvent;
use Promise;
use Promised::Flow;
use Promised::File;
use Promised::Plackup;
use Promised::Mysqld;
use Promised::Docker::WebDriver;
use Test::AccountServer;
use MIME::Base64;
use JSON::PS;
use Web::UserAgent::Functions qw(http_get http_post);
use Web::URL;
use Web::URL::Encoding;
use Web::Transport::ConnectionClient;
use Test::X1;
use Test::More;
use Tests::Current;

our @EXPORT = (@JSON::PS::EXPORT,
               @Web::URL::Encoding::EXPORT,
               @Promised::Flow::EXPORT,
               @Test::X1::EXPORT,
               grep { not /^\$/ } @Test::More::EXPORT);

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

my $AccountServer;
my $AppServer;
my $OAuthServer;
my $Browsers = {};

my $root_path = path (__FILE__)->parent->parent->parent->absolute;

sub oauth_server ($) {
  $OAuthServer = Promised::Plackup->new;
  $OAuthServer->start_timeout (10*60);
  $OAuthServer->envs->{CLIENT_ID} = rand;
  $OAuthServer->envs->{CLIENT_SECRET} = rand;
  my $name = rand;
  $OAuthServer->envs->{ACCOUNT_ID} = $name;
  $OAuthServer->envs->{ACCOUNT_NAME} = $name . '-san';
  $OAuthServer->envs->{ACCOUNT_EMAIL} = $name . '@test';
  $OAuthServer->plackup ($root_path->child ('plackup'));
  $OAuthServer->set_option ('--host' => $_[0] || '127.0.0.1');
  $OAuthServer->set_app_code (q{
    use strict;
    use warnings;
    use Wanage::HTTP;
    use Wanage::URL;
    use Web::UserAgent::Functions qw(http_post);
    use JSON::PS;
    use MIME::Base64;
    use Data::Dumper;
    use Web::Encoding;

    sub d ($) {
      if (defined $_[0]) {
        return decode_web_utf8 $_[0];
      } else {
        return undef;
      }
    } # d

    my $ClientID = $ENV{CLIENT_ID};
    my $ClientSecret = $ENV{CLIENT_SECRET};
    my $AccountName = $ENV{ACCOUNT_NAME};
    my $AccountEmail = $ENV{ACCOUNT_EMAIL};
    my $Sessions = {};
    sub {
      my $env = shift;
      my $http = Wanage::HTTP->new_from_psgi_env ($env);
      my $path = $http->url->{path};
      my $auth_params = {};
      if (($http->get_request_header ('Authorization') // '') =~ /^\s*[Oo][Aa][Uu][Tt][Hh]\s+(.+)$/) {
        $auth_params = {map { map { s/^"//; s/"$//; percent_decode_c $_ } split /=/, $_, 2 } split /\s*,\s*/, $1};
      }
      if ($path eq '/oauth1/temp') {
        my $temp_token = rand;
        my $session = $Sessions->{$temp_token} = {
          temp_token => $temp_token,
          temp_token_secret => rand,
          callback => $auth_params->{oauth_callback},
        };
        if (defined $session->{callback}) {
          $http->send_response_body_as_text
              (sprintf 'oauth_token=%s&oauth_token_secret=%s&oauth_callback_confirmed=true',
                   percent_encode_c $session->{temp_token},
                   percent_encode_c $session->{temp_token_secret});
        } else {
          $http->set_status (400);
          $http->send_response_body_as_text ('Bad callback URL');
        }
      } elsif ($path eq '/oauth1/authorize') {
        my $session = $Sessions->{$auth_params->{oauth_token} //
                                  $http->query_params->{oauth_token}->[0] //
                                  $http->request_body_params->{oauth_token}->[0]};
        if (not defined $session) {
          $http->set_status (400);
          $http->send_response_body_as_text ("Bad |oauth_token|");
        } elsif ($http->request_method eq 'POST') {
          $session->{code} = rand;
          $session->{account_id} = d $http->request_body_params->{account_id}->[0];
          $session->{account_name} = d $http->request_body_params->{account_name}->[0];
          $session->{account_email} = d $http->request_body_params->{account_email}->[0];
          $session->{account_no_id} = d $http->request_body_params->{account_no_id}->[0];
          $http->set_status (302);
          my $url = $session->{callback} // 'data:text/plain,no callback URL';
          $url .= $url =~ /\?/ ? '&' : '?';
          $url .= sprintf 'oauth_verifier=%s', percent_encode_c $session->{code};
          $http->set_response_header ('Location' => $url);
        } else {
          $http->set_response_header ('Content-Type', 'text/html; charset=utf-8');
          $http->send_response_body_as_text (q{
            <form method=post action>
              <input type=submit>
            </form>
          });
        }
      } elsif ($path eq '/oauth1/token') {
        my $session = $Sessions->{$auth_params->{oauth_token} //
                                  $http->query_params->{oauth_token}->[0] //
                                  $http->request_body_params->{oauth_token}->[0]};
        if (not defined $session) {
          $http->set_status (400);
          $http->send_response_body_as_text ("Bad |oauth_token|");
        } elsif ($auth_params->{oauth_verifier} eq $session->{code} and
                 $auth_params->{oauth_consumer_key} =~ /\A\Q$ClientID\E\.oauth1(\.\w+|)\z/) {
          delete $Sessions->{$auth_params->{oauth_token}};
          my $token = rand;
          my $no_id = $session->{account_no_id};
          my $session = $Sessions->{$token} = {
            access_token => $token,
            access_token_secret => rand,
            account_id => $session->{account_id} // int rand 100000,
            account_name => $session->{account_name} // $AccountName,
            account_email => $session->{account_email} // $AccountEmail,
          };
          if ($no_id) {
            delete $session->{account_id};
            delete $session->{account_key};
            $http->send_response_body_as_text
                (sprintf q{oauth_token=%s&oauth_token_secret=%s&display_name=%s&email_addr=%s},
                     percent_encode_c $session->{access_token},
                     percent_encode_c $session->{access_token_secret}.$1,
                     percent_encode_c $session->{account_name},
                     percent_encode_c $session->{account_email});
          } else {
            $http->send_response_body_as_text
                (sprintf q{oauth_token=%s&oauth_token_secret=%s&url_name=%s&display_name=%s&email_addr=%s},
                     percent_encode_c $session->{access_token},
                     percent_encode_c $session->{access_token_secret}.$1,
                     percent_encode_c $session->{account_id},
                     percent_encode_c $session->{account_name},
                     percent_encode_c $session->{account_email});
          }
        } else {
          $http->send_response_body_as_text (Dumper {
            _ => 'Bad auth-params',
            params => $auth_params,
          });
        }
      }

      if ($path eq '/oauth2/authorize') {
        my $callback = $http->query_params->{redirect_uri}->[0];
        if (not defined $callback) {
          $http->set_status (400);
          $http->send_response_body_as_text ('Bad callback URL');
        } elsif ($http->request_method eq 'POST') {
          my $code = rand;
          my $session = $Sessions->{$code} = {
            callback => $callback,
            code => $code,
            state => $http->query_params->{state}->[0],
            account_id => d $http->request_body_params->{account_id}->[0],
            account_name => d $http->request_body_params->{account_name}->[0],
            account_email => d $http->request_body_params->{account_email}->[0],
            account_no_id => $http->request_body_params->{account_no_id}->[0],
          };
          $http->set_status (302);
          my $url = $callback // 'data:text/plain,no callback URL';
          $url .= $url =~ /\?/ ? '&' : '?';
          $url .= sprintf 'code=%s&state=%s',
              percent_encode_c $session->{code},
              percent_encode_c $session->{state};
          $http->set_response_header ('Location' => $url);
        } else {
          $http->set_response_header ('Content-Type', 'text/html; charset=utf-8');
          $http->send_response_body_as_text (q{
            <form method=post action>
              <input type=submit>
            </form>
          });
        }
      } elsif ($path eq '/oauth2/token') {
        my $params = $http->request_body_params;
        my $session = $Sessions->{$params->{code}->[0]};
        if (not defined $session) {
          $http->set_status (400);
          $http->send_response_body_as_text ("Bad |code|");
        } elsif ($params->{redirect_uri}->[0] eq $session->{callback} and
                 $params->{client_id}->[0] =~ /\A\Q$ClientID\E\.oauth2(\.\w+|)\z/ and
                 $params->{client_secret}->[0] =~ /\A\Q$ClientSecret\E\.oauth2(\Q$1\E)\z/) {
          my $token = rand;
          my $no_id = $session->{account_no_id};
          my $session = $Sessions->{$token} = {
            access_token => $token,
            #access_token_secret => rand,
            account_id => $session->{account_id} // int rand 100000,
            account_name => $session->{account_name} // $AccountName,
            account_email => $session->{account_email} // $AccountEmail,
          };
          if ($no_id) {
            delete $session->{account_id};
            delete $session->{account_key};
          }
          $http->set_response_header ('Content-Type' => 'application/json');
          $http->send_response_body_as_text (perl2json_bytes +{
            access_token => $session->{access_token}.$1,
          });
          delete $Sessions->{$params->{code}->[0]};
        } else {
          $http->send_response_body_as_text (Dumper {
            _ => 'Bad params',
            params => $params,
          });
        }
      }

      if ($path eq '/profile') {
        $http->get_request_header ('Authorization') =~ /^token\s+(.+?)(?:\.SK2|)$/;
        my $session = $Sessions->{$1 // ''};
        if (defined $session) {
          $http->set_response_header ('Content-Type' => 'application/json');
          $http->send_response_body_as_text (perl2json_chars +{
            id => $session->{account_id},
            name => $session->{account_name},
            email => $session->{account_email},
          });
        } else {
          $http->set_status (403);
          $http->send_response_body_as_text ("Bad bearer");
        }
      }

      $http->close_response_body;
      return $http->send_response;
    };
  });
  return $OAuthServer->start;
} # oauth_server

sub start_web_server (;$$$) {
  my $web_host = $_[0];
  my $oauth_host = $_[1] || $web_host;
  my $oauth_hostname_for_docker = $_[2];

  return oauth_server ($oauth_host)->then (sub {
    my $host = $OAuthServer->get_host;
    $AccountServer = Test::AccountServer->new ({
      app_servers => {
        oauth1server => {
          name => 'oauth1server',
          url_scheme => 'http',
          host => $host,
          "temp_endpoint" => "/oauth1/temp",
          "temp_params" => {"scope" => ""},
          "auth_endpoint" => "/oauth1/authorize",
          auth_host => (($oauth_hostname_for_docker // $OAuthServer->get_hostname) . ':' . $OAuthServer->get_port),
          "token_endpoint" => "/oauth1/token",
          "token_res_params" => ["url_name", "display_name", 'email_addr'],
          "linked_name_field" => "display_name",
          "linked_id_field" => "url_name",
          "linked_email_field" => "email_addr",
          timeout => 60*10,
        },
        oauth2server => {
          name => 'oauth2server',
          url_scheme => 'http',
          host => $host,
          auth_endpoint => '/oauth2/authorize',
          auth_host => (($oauth_hostname_for_docker // $OAuthServer->get_hostname) . ':' . $OAuthServer->get_port),
          token_endpoint => '/oauth2/token',
          "profile_endpoint" => "/profile",
          "profile_id_field" => "id",
          "profile_key_field" => "login",
          "profile_name_field" => "name",
          "profile_email_field" => "email",
          "auth_scheme" => "token",
          "linked_id_field" => "profile_id",
          "linked_key_field" => "profile_key",
          "linked_name_field" => "profile_name",
          "linked_email_field" => "profile_email",
          "scope_separator" => ",",
          timeout => 60*10,
        },
        oauth2server_wrapped => {
          name => 'oauth2server_wrapped',
          url_scheme => 'http',
          host => $host,
          auth_endpoint => '/oauth2/authorize',
          auth_host => (($oauth_hostname_for_docker // $OAuthServer->get_hostname) . ':' . $OAuthServer->get_port),
          token_endpoint => '/oauth2/token',
          "profile_endpoint" => "/profile",
          "profile_id_field" => "id",
          "profile_key_field" => "login",
          "profile_name_field" => "name",
          "profile_email_field" => "email",
          "auth_scheme" => "token",
          "linked_id_field" => "profile_id",
          "linked_key_field" => "profile_key",
          "linked_name_field" => "profile_name",
          "linked_email_field" => "profile_email",
          "scope_separator" => ",",
          timeout => 60*10,
          cb_wrapper_url => 'http://cb.wrapper.test/wrapper/%s?url=%s&test=1',
        },
        ssh => {
          name => 'ssh',
        },
      }, # app_servers
      app_config => {
        "oauth1server.client_id" => $OAuthServer->envs->{CLIENT_ID}.".oauth1",
        "oauth1server.client_secret" => $OAuthServer->envs->{CLIENT_SECRET}.".oauth1",
        "oauth2server.client_id" => $OAuthServer->envs->{CLIENT_ID}.".oauth2",
        "oauth2server.client_secret" => $OAuthServer->envs->{CLIENT_SECRET}.".oauth2",
        "oauth1server.client_id.sk2" => $OAuthServer->envs->{CLIENT_ID}.".oauth1.SK2",
        "oauth1server.client_secret.sk2" => $OAuthServer->envs->{CLIENT_SECRET}.".oauth1.SK2",
        "oauth2server.client_id.sk2" => $OAuthServer->envs->{CLIENT_ID}.".oauth2.SK2",
        "oauth2server.client_secret.sk2" => $OAuthServer->envs->{CLIENT_SECRET}.".oauth2.SK2",
      }, # app_config
    });
    return $AccountServer->start->then (sub {
      my $data = $_[0];
      $data->{oauth1_auth_url} = sprintf q<http://%s/oauth1/authorize>, $host;
      $data->{oauth2_auth_url} = sprintf q<http://%s/oauth2/authorize>, $host;
      return $data;
    });
  });
} # start_web_server

push @EXPORT, qw(web_server);
sub web_server (;$$$) {
  return start_web_server (@_)->to_cv;
} # web_server

sub app_server ($$$) {
  my ($app_hostname, $api_token, $api_host) = @_;
  $AppServer = Promised::Plackup->new;
  $AppServer->start_timeout (10*60);
  $AppServer->plackup ($root_path->child ('plackup'));
  $AppServer->set_option ('--host' => $app_hostname);
  $AppServer->envs->{API_TOKEN} = $api_token;
  $AppServer->envs->{API_HOST} = $api_host;
  $AppServer->set_app_code (q{
    use Wanage::HTTP;
    use Wanage::URL;
    use AnyEvent;
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
        my $cv = AE::cv;
        http_post
            url => qq<http://$host/session>,
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              sk => $http->request_cookies->{sk},
              sk_context => $http->query_params->{sk_context}->[0] // 'app.cookie',
            },
            timeout => 60*10,
            anyevent => 1,
            cb => sub {
              $cv->send ($_[1]);
            };
        my $res = $cv->recv;
        my $json = json_bytes2perl $res->content;
        $http->set_response_cookie (sk => $json->{sk}, expires => $json->{sk_expires}, path => q</>, httponly => 0, secure => 0)
            if $json->{set_sk};

        my $cb_url = $http->url->resolve_string ('/cb?')->stringify;
        $cb_url .= '&bad_state=1' if $http->query_params->{bad_state}->[0];
        $cb_url .= '&bad_code=1' if $http->query_params->{bad_code}->[0];
        $cb_url .= '&sk_context=' . percent_encode_c $http->query_params->{sk_context}->[0] if defined $http->query_params->{sk_context}->[0];
        my $cv = AE::cv;
        http_post
            url => qq<http://$host/login?app_data=> . (percent_encode_b $http->query_params->{app_data}->[0] // ''),
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              sk => $json->{sk},
              sk_context => $http->query_params->{sk_context}->[0] // 'app.cookie',
              server => $http->query_params->{server},
              callback_url => $cb_url,
              create_email_link => $http->query_params->{create_email_link},
            },
            timeout => 60*10,
            anyevent => 1,
            cb => sub {
              $cv->send ($_[1]);
            };
        my $res = $cv->recv;
        my $json = json_bytes2perl $res->content;
        my $url = $json->{authorization_url};
        if (defined $url) {
          $http->set_status (302);
          $http->set_response_header (Location => $url);
        } else {
          $http->set_status (400);
          $http->send_response_body_as_text (perl2json_chars_for_record $json);
        }
      } elsif ($path eq '/cb') {
        my $cv = AE::cv;
        http_post
            url => qq<http://$host/cb>,
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              sk => $http->request_cookies->{sk},
              sk_context => $http->query_params->{sk_context}->[0] // 'app.cookie',
              oauth_token => $http->query_params->{oauth_token},
              oauth_verifier => $http->query_params->{bad_code} ? 'bee' : $http->query_params->{oauth_verifier},
              code => $http->query_params->{bad_code} ? 'bee' : $http->query_params->{code},
              state => $http->query_params->{bad_state} ? 'aaa' : $http->query_params->{state},
            },
            timeout => 60*10,
            anyevent => 1,
            cb => sub {
              $cv->send ($_[1]);
            };
        my $res = $cv->recv;
        if ($res->code == 200) {
          my $json = json_bytes2perl $res->content;
          $http->set_status (200);
          $http->send_response_body_as_text (encode_base64 perl2json_bytes {status => $res->code, app_data => $json->{app_data}});
        } else {
          $http->set_status (400);
          $http->send_response_body_as_text ($res->code);
        }
      } elsif ($path eq '/info') {
        my $cv = AE::cv;
        http_post
            url => qq<http://$host/info>,
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              sk => $http->request_cookies->{sk},
              sk_context => $http->query_params->{sk_context}->[0] // 'app.cookie',
              with_linked => $http->query_params->{with_linked},
              with_data => $http->query_params->{with_data},
            },
            timeout => 60*10,
            anyevent => 1,
            cb => sub {
              $cv->send ($_[1]);
            };
        my $res = $cv->recv;
        $http->send_response_body_as_ref (\($res->content));
      } elsif ($path eq '/profiles') {
        my $cv = AE::cv;
        http_post
            url => qq<http://$host/profiles>,
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              account_id => $http->query_params->{account_id},
            },
            timeout => 60*10,
            anyevent => 1,
            cb => sub {
              $cv->send ($_[1]);
            };
        my $res = $cv->recv;
        $http->send_response_body_as_ref (\($res->content));
      } elsif ($path eq '/token') {
        my $cv = AE::cv;
        http_post
            url => qq<http://$host/token>,
            header_fields => {Authorization => 'Bearer ' . $api_token},
            params => {
              sk => $http->request_cookies->{sk},
              sk_context => $http->query_params->{sk_context}->[0] // 'app.cookie',
              server => $http->query_params->{server},
            },
            timeout => 60*10,
            anyevent => 1,
            cb => sub {
              $cv->send ($_[1]);
            };
        my $res = $cv->recv;
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
  my $wd = $Browsers->{chrome} = Promised::Docker::WebDriver->chrome;
  $wd->start->then (sub {
    my $cv1 = web_server ('127.0.0.1', '0.0.0.0', $wd->get_docker_host_hostname_for_container);
    $cv1->cb (sub {
      my $data = $_[0]->recv;
      $data->{wd_url} = $wd->get_url_prefix;
      my $api_token = $data->{keys}->{'auth.bearer'};
      my $api_host = '127.0.0.1:' . $AccountServer->get_web_port;
      app_server ('0.0.0.0', $api_token, $api_host)->then (sub {
        $data->{host_for_browser} = $wd->get_docker_host_hostname_for_container . ':' . $AppServer->get_port;
        # XXX should be replaced with new style
        $data->{oauth_server_account_name} = $OAuthServer->envs->{ACCOUNT_NAME};
        $data->{oauth_server_account_email} = $OAuthServer->envs->{ACCOUNT_EMAIL};
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
  for ($AccountServer, $AppServer, $OAuthServer, values %$Browsers) {
    next unless defined $_;
    $cv->begin;
    $_->stop->then (sub { $cv->end });
  }
  $cv->end;
  $cv->recv;
} # stop_web_server

push @EXPORT, qw(stop_web_server_and_driver);
*stop_web_server_and_driver = \&stop_web_server;

push @EXPORT, qw(GET);
sub GET ($$;%) {
  my ($c, $path, %args) = @_;
  my $host = $c->received_data->{host};
  if ($args{session}) {
    $args{params}->{sk_context} //= 'tests';
    $args{params}->{sk} //= $args{session}->{sk};
  }
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_get
        url => qq<http://$host$path>,
        header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
        params => $args{params},
        anyevent => 1,
        max_redirect => 0,
        timeout => 60*10,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } else {
            $ng->($res->code);
          }
        };
  });
} # GET

push @EXPORT, qw(POST);
sub POST ($$;%) {
  my ($c, $path, %args) = @_;
  my $host = $c->received_data->{host};
  if ($args{session}) {
    $args{params}->{sk_context} //= 'tests';
    $args{params}->{sk} //= $args{session}->{sk};
  }
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post
        url => qq<http://$host$path>,
        header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'} . ($args{bad_bearer} ? 'a' : '')},
        params => $args{params},
        anyevent => 1,
        max_redirect => 0,
        timeout => 60*10,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } elsif ($res->code == 400 and $res->header ('Content-Type') =~ m{^application/json\b}) {
            $ng->(json_bytes2perl $res->content);
          } else {
            $ng->($res->code);
          }
        };
  });
} # POST

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
        timeout => 60*10,
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
    $args{account} = {} unless ref $args{account};
    $p = $p->then (sub {
      my $session = $_[0];
      return Promise->new (sub {
        my ($ok, $ng) = @_;
        my $host = $c->received_data->{host};
        http_post
            url => qq<http://$host/create>,
            header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'auth.bearer'}},
            params => {
              sk_context => 'tests', sk => $session->{sk},
              name => $args{account}->{name},
              user_status => $args{account}->{user_status},
              admin_status => $args{account}->{admin_status},
            },
            anyevent => 1,
            max_redirect => 0,
            timeout => 60*10,
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

    if (defined $args{account}->{email}) {
      $p = $p->then (sub {
        my $session = $_[0];
        return POST ($c, q</email/input>, params => {
          addr => $args{account}->{email},
        }, session => $session)->then (sub {
          my $json = $_[0];
          return POST ($c, q</email/verify>, params => {
            key => $json->{key},
          }, session => $session);
        })->then (sub {
          return $session;
        });
      });
    }
  }

  return $p;
} # session

my $TestWait = AE::cv;
push @EXPORT, qw(Test);
sub Test (&;%) {
  my $code = shift;
  test (sub {
    my $current = bless {context => $_[0]}, 'Tests::Current';
    promised_cleanup {
      return $current->done;
    } Promise->resolve ($current)->then ($code)->catch (sub {
      my $error = $_[0];
      test {
        ok 0, 'No exception';
        is $error, undef, 'No exception';
      } $current->c;
    });
  }, wait => $TestWait, @_);
} # Test

push @EXPORT, qw(RUN);
sub RUN () {
  $TestWait->send (start_web_server->to_cv->recv); # XXX or throw
  run_tests;
  undef $TestWait;
  stop_web_server;
} # RUN

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
