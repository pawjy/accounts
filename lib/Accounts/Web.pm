package Accounts::Web;
use strict;
use warnings;
use Path::Tiny;
use File::Temp;
use Time::HiRes qw(time);
use Promise;
use Promised::File;
use Promised::Command;
use JSON::PS;
use Digest::SHA qw(sha1_hex);
use Crypt::PK::Ed25519;
use Wanage::URL;
use Wanage::HTTP;
use Dongry::Type;
use Dongry::Type::JSONPS;
use Dongry::SQL;
use Accounts::AppServer;
use Web::URL;
use Web::Encoding;
use Web::DateTime::Clock;
use Web::DOM::Document;
use Web::XML::Parser;
use Web::Transport::AWS;
use Web::Transport::OAuth1;
use Web::Transport::ConnectionClient;
use Web::Transport::BasicClient;
use Web::Transport::Base64;

sub format_id ($) {
  return sprintf '%llu', $_[0];
} # format_id

## Some end points accept "status filter" parameters.  If an end point
## accepts status filter for field /f/ with prefix /p/, the end points
## can receive parameters whose name is /p//f/.  If one or more
## parameter values with that name are specified, only items whose
## field /f/'s value is one of those parameter values are returned.
## Otherwise, any available item is returned.
##
## For example, /info accepts |group_owner_status| parameter for field
## |owner_status| with prefix |group_|.  If
## |group_owner_status=1&group_owner_status=2| is specified, only
## items whose |owner_status| is |1| or |2| are returned.  If no
## |group_owner_status| parameter is specified, all items are
## returned.
sub status_filter ($$@) {
  my ($app, $prefix, @name) = @_;
  my $result = {};
  for my $name (@name) {
    my $values = $app->bare_param_list ($prefix . $name);
    $result->{$name} = {-in => $values} if @$values;
  }
  return %$result;
} # status_filter

my $DEBUG = $ENV{ACCOUNTS_DEBUG};

sub psgi_app ($$) {
  my ($class, $config) = @_;
  return sub {
    ## This is necessary so that different forked siblings have
    ## different seeds.
    srand;

    ## XXX Parallel::Prefork (?)
    delete $SIG{CHLD};
    delete $SIG{CLD};

    my $http = Wanage::HTTP->new_from_psgi_env ($_[0]);
    my $app = Accounts::AppServer->new_from_http_and_config ($http, $config);

    my $start_time = time;
    my $access_id = int rand 1000000;
    warn sprintf "Access[%d]: [%s] %s %s\n",
        $access_id, scalar gmtime $start_time,
        $app->http->request_method, $app->http->url->stringify
        if $DEBUG;

    return $app->execute_by_promise (sub {
      return Promise->resolve->then (sub {
        return $class->main ($app);
      })->then (sub {
        return $app->shutdown;
      }, sub {
        my $error = $_[0];
        return $app->shutdown->then (sub { die $error });
      })->catch (sub {
        return if UNIVERSAL::isa ($_[0], 'Warabe::App::Done');
        $app->error_log ($_[0]);
        die $_[0];
      })->finally (sub {
        return unless $DEBUG;
        warn sprintf "Access[%d]: %f s\n",
            $access_id, time - $start_time;
      });
    });
  };
} # psgi_app

## If an end point supports paging, following parameters are
## available:
##   ref       A short string identifying the page
##   limit     The maximum number of the returned items (i.e. page size)
##
## If the processing of the end point has succeeded, the result JSON
## has following fields:
##   has_next  Whether there is next page or not (at the time of the operation)
##   next_ref  The |ref| parameter value for the next page

sub this_page ($%) {
  my ($app, %args) = @_;
  my $page = {
    order_direction => 'DESC',
    limit => 0+($app->bare_param ('limit') // $args{limit} // 30),
    offset => 0,
    value => undef,
  };
  my $max_limit = $args{max_limit} // 100;
  return $app->throw_error_json ({reason => "Bad |limit|"})
      if $page->{limit} < 1 or $page->{limit} > $max_limit;
  my $ref = $app->bare_param ('ref');
  if (defined $ref) {
    if ($ref =~ /\A([+-])([0-9.]+),([0-9]+)\z/) {
      $page->{order_direction} = $1 eq '+' ? 'ASC' : 'DESC';
      $page->{exact_value} = 0+$2;
      $page->{value} = {($page->{order_direction} eq 'ASC' ? '>=' : '<='), $page->{exact_value}};
      $page->{offset} = 0+$3;
      return $app->throw_error_json ({reason => "Bad |ref| offset"})
          if $page->{offset} > 100;
      $page->{ref} = $ref;
    } else {
      return $app->throw_error_json ({reason => "Bad |ref|"});
    }
  }
  return $page;
} # this_page

sub next_page ($$$) {
  my ($this_page, $items, $value_key) = @_;
  my $next_page = {};
  my $sign = $this_page->{order_direction} eq 'ASC' ? '+' : '-';
  my $values = {};
  $values->{$this_page->{exact_value}} = $this_page->{offset}
      if defined $this_page->{exact_value};
  if (ref $items eq 'ARRAY') {
    if (@$items) {
      my $last_value = $items->[0]->{$value_key};
      for (@$items) {
        $values->{$_->{$value_key}}++;
        if ($sign eq '+') {
          $last_value = $_->{$value_key} if $last_value < $_->{$value_key};
        } else {
          $last_value = $_->{$value_key} if $last_value > $_->{$value_key};
        }
      }
      $next_page->{next_ref} = $sign . $last_value . ',' . $values->{$last_value};
      $next_page->{has_next} = @$items == $this_page->{limit};
    } else {
      $next_page->{next_ref} = $this_page->{ref};
      $next_page->{has_next} = 0;
    }
  } else { # HASH
    if (keys %$items) {
      my $last_value = $items->{each %$items}->{$value_key};
      for (values %$items) {
        $values->{$_->{$value_key}}++;
        if ($sign eq '+') {
          $last_value = $_->{$value_key} if $last_value < $_->{$value_key};
        } else {
          $last_value = $_->{$value_key} if $last_value > $_->{$value_key};
        }
      }
      $next_page->{next_ref} = $sign . $last_value . ',' . $values->{$last_value};
      $next_page->{has_next} = (keys %$items) == $this_page->{limit};
    } else {
      $next_page->{next_ref} = $this_page->{ref};
      $next_page->{has_next} = 0;
    }
  }
  return $next_page;
} # next_page

{
  my @alphabet = ('A'..'Z', 'a'..'z', 0..9);
  sub id ($) {
    my $key = '';
    $key .= $alphabet[rand @alphabet] for 1..$_[0];
    return $key;
  } # id
}

sub create_lk ($$) {
  my ($config, $origin) = @_;

  return unless defined $config->get ('lk_private_key');
  
  my $x = '' . time;
  my $m = (encode_web_utf8 $origin) . ':' . $x;

  my $key = Crypt::PK::Ed25519->new;
  $key->import_key_raw ($config->get_binary ('lk_private_key'), 'private');
  my $sig = $key->sign_message ($m);

  $x .= ':' . encode_web_base64 $sig;
  return $x;
} # create_lk

sub verify_lk ($$$$) {
  my ($config, $lk, $origin, $lk_expires) = @_;

  return 0 unless defined $config->get ('lk_public_key');
  return 0 unless $lk =~ /\A([0-9]+\.[0-9]+):([^:]+)\z/;
  return 0 if $1 > $lk_expires;
  my $sig = decode_web_base64 $2;

  my $m = (encode_web_utf8 $origin) . ':' . $1;

  my $key = Crypt::PK::Ed25519->new;
  $key->import_key_raw ($config->get_binary ('lk_public_key'), 'public');
  my $result = $key->verify_message ($sig, $m);

  return $result;
} # verify_lk

my $MaxSessionTimeout = 60*60*24*10;

## Operation source parameters.
##
##   |source_ua|     : Bytes :  The source |User-Agent| header, if any.
##   |source_ipaddr| : Bytes :  The source IP address, if any.
##   |source_data|   : JSON :   Application-dependent source data, if any.

sub main ($$) {
  my ($class, $app) = @_;
  my $path = $app->path_segments;

  $app->http->response_timing_enabled
      ($app->http->get_request_header ('x-timing'));
  $app->db->connect ('master'); # preconnect

  if ($path->[0] eq 'group') {
    return $class->group ($app, $path);
  }

  if ($path->[0] eq 'invite') {
    return $class->invite ($app, $path);
  }

  if ($path->[0] eq 'icon') {
    return $class->icon ($app, $path);
  }

  if (@$path == 1 and $path->[0] eq 'session') {
    ## /session - Ensure that there is a session
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $sk = $app->bare_param ('sk') // '';
    my $sk_context = $app->bare_param ('sk_context')
        // return $app->throw_error_json ({reason => 'No |sk_context|'});
    return ((length $sk ? $app->db->select ('session', {
      sk => $sk,
      sk_context => $sk_context,
      expires => {'>', time},
    }, fields => ['sk', 'expires'], source_name => 'master')->then (sub {
      return $_[0]->first_as_row; # or undef
    }) : Promise->resolve (undef))->then (sub {
      my $session_row = $_[0];
      if (defined $session_row) {
        return [$session_row, 0];
      } else {
        $sk = id 100;
        my $time = time;
        my $age = $MaxSessionTimeout;
        my $ma = $app->config->get ('session_max_age') || 'Infinity';
        $age = $ma if $ma < $age;
        return $app->db->insert ('session', [{
          sk => $sk,
          sk_context => $sk_context,
          created => $time,
          expires => $time + $age,
          data => '{}',
        }], source_name => 'master')->then (sub {
          $session_row = $_[0]->first_as_row;
          return [$session_row, 1];
        });
      }
    })->then (sub {
      my ($session_row, $new) = @{$_[0]};
      my $json = {sk => $session_row->get ('sk'),
                  sk_expires => $session_row->get ('expires'),
                  set_sk => $new?1:0};
      return $app->send_json ($json);
    })->then (sub {
      return $class->delete_old_sessions ($app);
    }));
  } # /session

  if (@$path == 1 and $path->[0] eq 'create') {
    ## /create - Create an account (without link)
    ##
    ##   |sk_context|, |sk|
    ##   login_time : Timestamp? :  The value of the account's session's
    ##                              login time.  If missing, defaulted to
    ##                              the current time.
    ##   Operation source parameters.
    ##
    ##   Create an account and associate the session with it.
    ##
    ##   The session must not be associated with any account.  If
    ##   associated, an error is returned.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0]
          // return $app->send_error_json ({reason => 'Bad session',
                                            error_for_dev => "/create bad session"});
      my $session_data = $session_row->get ('data');
      if (defined $session_data->{account_id}) {
        return $app->send_error_json ({reason => 'Account-associated session'});
      }

      return $app->db->uuid_short (2, source_name => 'master')->then (sub {
        my $ids = $_[0];
        my $account_id = '' . $ids->[0];
        my $time = time;
        my $ver = 0+($app->bare_param ('terms_version') // 0);
        $ver = 255 if $ver > 255;
        return $app->db->insert ('account', [{
          account_id => $account_id,
          created => $time,
          name => Dongry::Type->serialize ('text', $app->text_param ('name') // $account_id),
          user_status => $app->bare_param ('user_status') // 1,
          admin_status => $app->bare_param ('admin_status') // 1,
          terms_version => $ver,
        }], source_name => 'master')->then (sub {
          $session_data->{account_id} = $account_id;
          $session_data->{login_time} = 0+($app->bare_param ('login_time') || time);
          $session_data->{no_email} = 1;
          return $session_row->update ({data => $session_data}, source_name => 'master');
        })->then (sub {
          my $data = {
            source_operation => 'create',
          };
          my $app_obj = $app->bare_param ('source_data');
          $data->{source_data} = json_bytes2perl $app_obj if defined $app_obj;
          return $app->db->insert ('account_log', [{
            log_id => $ids->[1],
            account_id => $account_id,
            operator_account_id => $account_id,
            timestamp => $time,
            action => 'create',
            ua => $app->bare_param ('source_ua') // '',
            ipaddr => $app->bare_param ('source_ipaddr') // '',
            data => Dongry::Type->serialize ('json', $data),
          }]); # since R5.9
        })->then (sub {
          return $app->send_json ({
            account_id => $account_id,
            account_log_id => '' . $ids->[1],
          });
        });
      });
    });
  } # /create

  if (@$path == 1 and
      ($path->[0] eq 'login' or $path->[0] eq 'link')) {
    ## /login - Start OAuth flow to associate session with account
    ## /link - Start OAuth flow to associate session's account with account
    ##   |sk_context|, |sk|
    ##   |server|       - The server name.  Required.
    ##   |callback_url| - An absolute URL, used as the OAuth redirect URL.
    ##                    Required.
    ##   |lk|           - The |lk| cookie value, if any.
    ##   |origin|       - The origin of the server.  Required if |lk|.
    ##
    ##   Initiate the OAuth flow.  Then:
    ##
    ##     /login - If it successfully returns an external account (in
    ##     /cb), find accounts in our database associated with that
    ##     external account.  If found, the session is associated with
    ##     the account.  Otherwise, a new account is created and the
    ##     session is associated with it.
    ##
    ##     /link - If it successfully returns an external account (in
    ##     /cb), associate that external account with the session's
    ##     account.  If the |server| does not associate a unique
    ##     identifier to the external account, any existing external
    ##     account with same |server| is associated with the session's
    ##     account is replaced with the new one.
    ##
    ##   In /login, the session must not be associated with any
    ##   account.  If associated, an error is returned.
    ##
    ##   In /link, the session must be associated with an account.
    ##   Otherwise, an error is returned.
    ##
    ##   If the definition for the selected server has
    ##   |cb_wrapper_url| property, instead of using the
    ##   |callback_url| as is, the result of replacing |%s|
    ##   placeholders in |cb_wrapper_url| by percent-encoded variant
    ##   of |callback_url| is used as the callback URL sent to the
    ##   server.
    ##
    ## Returns:
    ##
    ##   |is_new| : Boolean :  Whether it is a new login to the account or not.
    ##   |lk|  : cookie-value string? :  The |lk| cookie value, if necessary.
    ##   |lk_expires| : Timestamp? :     The expiration timestamp of |lk|.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0]
          // return $app->send_error_json ({reason => 'Bad session',
                                            error_for_dev => "/l* bad session"});
      my $session_data = $session_row->get ('data');
      if ($path->[0] eq 'link') {
        if (not defined $session_data->{account_id}) {
          return $app->send_error_json ({reason => 'Not a login user'});
        }
      } else {
        if (defined $session_data->{account_id}) {
          return $app->send_error_json ({reason => 'Account-associated session'});
        }
      }

      my $server = $app->config->get_oauth_server ($app->bare_param ('server'))
          or return $app->send_error_json ({reason => 'Bad |server|'});
      ## Application must specify a legal |callback_url| in the
      ## context of the application.
      my $cb = $app->text_param ('callback_url')
          // return $app->send_error_json ({reason => 'Bad |callback_url|'});
      if (defined $server->{cb_wrapper_url}) {
        my $url = $server->{cb_wrapper_url};
        $url =~ s{%s}{percent_encode_c $cb}ge;
        $cb = $url;
      }
      
      my $state = id 50;
      my $scope = join $server->{scope_separator} // ' ', grep { defined }
          ## Both /login and /link uses |login_scope|.
          $server->{login_scope},
          @{$app->text_param_list ('server_scope')};
      $session_data->{action} = {
        endpoint => 'oauth',
        operation => $path->[0], # login or link
        server => $server->{name},
        callback_url => $cb,
        state => $state,
        app_data => $app->text_param ('app_data'),
        create_email_link => $app->bare_param ('create_email_link'),
      };

      my $sk_context = $session_row->get ('sk_context');
      my $client_id = $app->config->get ($server->{name} . '.client_id.' . $sk_context) //
                      $app->config->get ($server->{name} . '.client_id');
      my $client_secret = $app->config->get ($server->{name} . '.client_secret.' . $sk_context) //
                          $app->config->get ($server->{name} . '.client_secret');

      return (defined $server->{temp_endpoint} ? do {
        $cb .= $cb =~ /\?/ ? '&' : '?';
        $cb .= 'state=' . $state;

        Web::Transport::OAuth1->request_temp_credentials (
          url_scheme => $server->{url_scheme},
          host => $server->{host},
          pathquery => $server->{temp_endpoint},
          oauth_callback => $cb,
          oauth_consumer_key => $client_id,
          client_shared_secret => $client_secret,
          params => {scope => $scope},
          auth => {host => $server->{auth_host}, pathquery => $server->{auth_endpoint}},
          timeout => $server->{timeout} || 10,
        )->then (sub {
          my $temp_token = $_[0]->{temp_token};
          my $temp_token_secret = $_[0]->{temp_token_secret};
          my $auth_url = $_[0]->{auth_url};
          $session_data->{action}->{temp_credentials} 
              = [$temp_token, $temp_token_secret];
          return $auth_url;
        });
      } : defined $server->{auth_endpoint} ? Promise->new (sub {
        my ($ok, $ng) = @_;
        my $auth_url = ($server->{url_scheme} || 'https') . q<://> . ($server->{auth_host} // $server->{host}) . ($server->{auth_endpoint}) . '?' . join '&', map {
          (percent_encode_c $_->[0]) . '=' . (percent_encode_c $_->[1])
        } (
          [client_id => $client_id],
          [redirect_uri => $cb],
          [response_type => 'code'],
          [state => $state],
          [scope => $scope],
        );
        $ok->($auth_url);
      }) : Promise->reject ($app->send_error_json ({reason => 'Not a loginable |server|'})))->then (sub {
        my $auth_url = $_[0];
        return $session_row->update ({data => $session_data}, source_name => 'master')->then (sub {
          return $app->send_json ({authorization_url => $auth_url});
        });
      })->then (sub {
        return $class->delete_old_sessions ($app);
      });
    });
  }

  if (@$path == 1 and $path->[0] eq 'cb') {
    ## /cb - Process OAuth callback
    ##
    ## Parameters
    ##
    ##   Operation source parameters.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      if (not defined $session_row) {
        my $reload = 0;
        if (not defined $app->bare_param ('sk') and
            defined $app->bare_param ('state') and
            not $app->bare_param ('reloaded')) {
          ## Some version of Safari does not send SameSite=Lax cookie
          ## when the fetch is initiated as part of cross-origin
          ## redirect navigation.
          $reload = 1;
        }
        return $app->send_error_json ({reason => 'Bad session',
                                       need_reload => $reload,
                                       error_for_dev => "/cb bad session"});
      }
      
      my $session_data = $session_row->get ('data');
      return $app->send_error_json ({reason => 'Bad callback call'})
          unless 'oauth' eq ($session_data->{action}->{endpoint} // '');

      my $actual_state = $app->bare_param ('state') // '';
      return $app->send_error_json ({reason => 'Bad |state|'})
          unless length $actual_state and
                 $actual_state eq $session_data->{action}->{state};

      my $server = $app->config->get_oauth_server
          ($session_data->{action}->{server})
          or $app->send_error (500);

      my $sk_context = $session_row->get ('sk_context');
      my $client_id = $app->config->get ($server->{name} . '.client_id.' . $sk_context) //
                      $app->config->get ($server->{name} . '.client_id');
      my $client_secret = $app->config->get ($server->{name} . '.client_secret.' . $sk_context) //
                          $app->config->get ($server->{name} . '.client_secret');

      my $p;
      if (defined $session_data->{action}->{temp_credentials}) { # OAuth 1.0
        my $token = $app->bare_param ('oauth_token') // '';
        my $verifier = $app->bare_param ('oauth_verifier') // '';
        return $app->send_error_json ({reason => 'No |oauth_verifier|'})
            unless length $verifier;
        $p = Web::Transport::OAuth1->request_token (
          url_scheme => $server->{url_scheme},
          host => $server->{host},
          pathquery => $server->{token_endpoint},
          oauth_consumer_key => $client_id,
          client_shared_secret => $client_secret,
          temp_token => $session_data->{action}->{temp_credentials}->[0],
          temp_token_secret => $session_data->{action}->{temp_credentials}->[1],
          oauth_token => $token,
          oauth_verifier => $verifier,
          timeout => $server->{timeout} || 10,
        )->then (sub {
          my $access_token = $_[0]->{token};
          my $access_token_secret = $_[0]->{token_secret};
          my $params = $_[0]->{params};
          $session_data->{$server->{name}}->{access_token} = [$access_token, $access_token_secret];
          for (@{$server->{token_res_params} or []}) {
            $session_data->{$server->{name}}->{$_} = $params->{$_};
          }
        });
      } else { # OAuth 2.0
        my $code = $app->bare_param ('code') // '';
        return $app->send_error_json ({reason => 'No |code|'})
            unless length $code;
        my $url = Web::URL->parse_string
            (($server->{url_scheme} // 'https') . '://' . $server->{host} . $server->{token_endpoint});
        my $client = Web::Transport::ConnectionClient->new_from_url ($url);
        $p = $client->request (
          method => 'POST',
          url => $url,
          params => {
            client_id => $client_id,
            client_secret => $client_secret,
            redirect_uri => $session_data->{action}->{callback_url},
            code => $app->text_param ('code'),
            grant_type => 'authorization_code',
          },
          # XXX timeout => $server->{timeout} || 10,
        )->then (sub {
          my $res = $_[0];
          die $res unless $res->status == 200;

          my $access_token;
          my $refresh_token;
          my $expires_at;
          if (($res->header ('content-type') // '') =~ /json/) { ## Standard
            my $json = json_bytes2perl $res->content;
            if (ref $json eq 'HASH' and defined $json->{access_token}) {
              $access_token = $json->{access_token};
              $refresh_token = $json->{refresh_token};
              $expires_at = $json->{expires_at};
            }
          } else { ## Facebook
            my $parsed = parse_form_urlencoded_b $res->content;
            $access_token = $parsed->{access_token}->[0];
            $refresh_token = $parsed->{refresh_token}->[0];
          }
          die "Access token request failed" unless defined $access_token;
          
          my $server_data = $session_data->{$server->{name}} ||= {};
          $server_data->{access_token} = $access_token;
          $server_data->{refresh_token} = $refresh_token; # or undef
          $server_data->{expires_at} = $expires_at; # or undef
        })->finally (sub {
          return $client->close;
        });
      } # OAuth 1/2

      return $p->then (sub {
        return Promise->resolve->then (sub {
          return $class->get_resource_owner_profile (
            $app,
            server => $server,
            session_data => $session_data,
            sk_context => $sk_context,
          );
        })->then (sub {
          my $data = $session_data->{$server->{name}} ||= {};
          my $linked = $data->{linked_data} ||= {};
          my $id = $data->{$server->{linked_id_field} // ''};
          my $key = $data->{$server->{linked_key_field} // ''};
          for (['page_url_template' => 'page_url'],
               ['icon_url_template' => 'icon_url']) {
            if (defined $server->{$_->[0]}) {
              $linked->{$_->[1]} = $server->{$_->[0]};
              if (defined $id) {
                $linked->{$_->[1]} =~ s/\{id\}/$id/g;
                $linked->{$_->[1]} =~ s/\{id:2\}/substr $id, 0, 2/ge;
              }
              if (defined $key) {
                $linked->{$_->[1]} =~ s/\{key\}/$key/g;
                $linked->{$_->[1]} =~ s/\{key:2\}/substr $key, 0, 2/ge;
              }
            }
          }
        })->then (sub {
          if ($session_data->{action}->{operation} eq 'login') {
            return $class->login_account ($app, $server, $session_data);
          } elsif ($session_data->{action}->{operation} eq 'link') {
            return $class->link_account ($app, $server, $session_data);
          } else {
            die "Bad operation |$session_data->{action}->{operation}|";
          }
        })->then (sub {
          my $app_data = $session_data->{action}->{app_data}; # or undef
          my $json = {app_data => $app_data};
          if ($session_data->{action}->{operation} eq 'login') {
            $session_data->{login_time} = time;

            my $lk = $app->bare_param ('lk') // '';
            my $origin = $app->bare_param ('origin') // '';
            my $lk_expires = time + 60*60*24*400;
            if (verify_lk ($app->config, $lk, $origin, $lk_expires)) {
              #
            } else {
              $json->{lk} = create_lk ($app->config, $origin);
              if (defined $json->{lk}) {
                $json->{lk_expires} = $lk_expires;
                $json->{is_new} = 1;
              }
            }
          }
          delete $session_data->{action};
          return $session_row->update ({data => $session_data}, source_name => 'master')->then (sub {
            return $app->send_json ($json);
          });
        });
      }, sub {
        warn $_[0];
        return $app->send_error_json ({reason => 'OAuth token endpoint failed',
                                       error_for_dev => "$_[0]"});
      })->then (sub {
        return $class->delete_old_sessions ($app);
      });
    });
  } # /cb

  if (@$path == 2 and $path->[0] eq 'email') {
    if ($path->[1] eq 'input') {
      ## /email/input - Associate an email address to the session
      $app->requires_request_method ({POST => 1});
      $app->requires_api_key;

      my $addr = $app->text_param ('addr') // '';
      unless ($addr =~ /\A[\x21-\x3F\x41-\x7E]+\@[\x21-\x3F\x41-\x7E]+\z/) {
        return $app->send_error_json ({reason => 'Bad email address'});
      }
      my $email_id = sha1_hex $addr;

      my $session_row;
      my $session_data;
      my $account_id;
      my $json = {};
      return $class->resume_session ($app)->then (sub {
        $session_row = $_[0]
            // return $app->throw_error_json ({reason => 'Bad session',
                                            error_for_dev => "/email/input bad session"});
        $session_data = $session_row->get ('data');
        $account_id = $session_data->{account_id}; # or undef

        if (defined $account_id) {
          return $app->db->select ('account_link', {
            account_id => Dongry::Type->serialize ('text', $account_id),
            service_name => 'email',
            linked_id => $email_id,
          }, source_name => 'master', fields => ['created'])->then (sub {
            if ($_[0]->first) {
              return 0;
            } else {
              return 1;
            }
          });
        } else {
          return 1;
        }
      })->then (sub {
        if ($_[0]) {
          $json->{key} = id 30;
          my $session_data = $session_row->get ('data');
          $session_data->{email_verifications}->{$json->{key}} = {
            addr => $addr,
            id => $email_id,
          };
          return $session_row->update ({data => $session_data}, source_name => 'master');
        }
      })->then (sub {
        return $app->send_json ($json);
      });
    }

    if ($path->[1] eq 'verify') {
      ## /email/verify - Save the email address association to the account
      ##
      ## Parameters
      ##
      ##   Operation source parameters.
      $app->requires_request_method ({POST => 1});
      $app->requires_api_key;

      my $key = $app->bare_param ('key') // '';
      return $app->db->transaction->then (sub {
        my $tr = $_[0];
        return Promise->resolve->then (sub {
          return $class->resume_session ($app, $tr);
        })->then (sub {
          my $session_row = $_[0]
              // return $app->throw_error_json ({reason => 'Bad session',
                                                 error_for_dev => "/email/verify bad session"});
          my $session_data = $session_row->get ('data');
          my $account_id = $session_data->{account_id}
              // return $app->throw_error_json ({reason => 'Not a login user'});
          my $def = $session_data->{email_verifications}->{$key}
              // return $app->throw_error_json ({reason => 'Bad key'});

          my $log_id;
          my $time = time;
          return $tr->execute ('SELECT UUID_SHORT() AS uuid, UUID_SHORT() AS uuid2', undef, source_name => 'master')->then (sub {
            my $v = $_[0]->first;
            $log_id = '' . $v->{uuid2};
            return $tr->insert ('account_link', [{
              account_link_id => $v->{uuid},
              account_id => Dongry::Type->serialize ('text', $account_id),
              service_name => 'email',
              created => $time,
              updated => $time,
              linked_name => '',
              linked_id => Dongry::Type->serialize ('text', $def->{id}), # or undef
              linked_key => undef,
              linked_email => Dongry::Type->serialize ('text', $def->{addr}),
              linked_token1 => '',
              linked_token2 => '',
              linked_data => '{}',
            }], source_name => 'master', duplicate => {
              updated => $app->db->bare_sql_fragment ('VALUES(updated)'),
            });
          })->then (sub {
            delete $session_data->{email_verifications}->{$key};
            delete $session_data->{no_email};
            return $tr->update ('session', {
              data => Dongry::Type->serialize ('json', $session_data),
            }, where => {
              sk => $session_row->get ('sk'),
            }, source_name => 'master');
          })->then (sub {
            my $data = {
              source_operation => 'email/verify',
              service_name => 'email',
              linked_email => $def->{addr},
              account_link_id => $log_id,
            };
            $data->{linked_id} = '' . $def->{id} if defined $def->{id};
            my $app_obj = $app->bare_param ('source_data');
            $data->{source_data} = json_bytes2perl $app_obj if defined $app_obj;
            return $tr->insert ('account_log', [{
              log_id => $log_id,
              account_id => Dongry::Type->serialize ('text', $account_id),
              operator_account_id => Dongry::Type->serialize ('text', $account_id),
              timestamp => $time,
              action => 'link',
              ua => $app->bare_param ('source_ua') // '',
              ipaddr => $app->bare_param ('source_ipaddr') // '',
              data => Dongry::Type->serialize ('json', $data),
            }]); # since R5.9
          });
        })->then (sub {
          return $tr->commit;
        }, sub {
          my $e = shift;
          return $tr->rollback->then (sub {
            die $e;
          });
        })->then (sub {
          return $app->send_json ({});
        });
      });
    }
  }

  if (@$path == 1 and $path->[0] eq 'token') {
    ## /token - Get access token of an OAuth server
    ##
    ##   |account_id|        - The account's ID.
    ##   |sk_context|, |sk|  - The session.  Either session or account ID is
    ##                         required.
    ##   |server|            - The server name.  Required.
    ##   |account_link_id| - The account link ID.  If specified, only the
    ##                    result for this specific account link, if any,
    ##                    is returned.  (Session or account ID is still
    ##                    significant.)  Otherwise, one of account links,
    ##                    if any, is chosen.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $server_name = $app->bare_param ('server') // '';
    my $server = $app->config->get_oauth_server ($server_name)
        or return $app->send_error (400, reason_phrase => 'Bad |server|');

    my $id = $app->bare_param ('account_id');
    my $session_row;
    return ((defined $id ? Promise->resolve ($id) : $class->resume_session ($app)->then (sub {
      $session_row = $_[0];
      return $session_row->get ('data')->{account_id} # or undef
          if defined $session_row;
      return undef;
    }))->then (sub {
      my $id = $_[0];
      return {} unless defined $id;
      my $json = {account_id => $id};
      my $link_id = $app->bare_param ('account_link_id');
      return $app->db->select ('account_link', {
        account_id => Dongry::Type->serialize ('text', $id),
        service_name => Dongry::Type->serialize ('text', $server->{name}),
        (defined $link_id ? (account_link_id => $link_id) : ()),
      }, source_name => 'master', fields => ['account_link_id', 'linked_token1', 'linked_token2'])->then (sub {
        my $r = $_[0]->first;
        if (defined $r) {
          if (defined $server->{temp_endpoint} or # OAuth 1.0
              $server->{name} eq 'ssh') {
            $json->{access_token} = [$r->{linked_token1}, $r->{linked_token2}]
                if length $r->{linked_token1} and length $r->{linked_token2};
          } else {
            # linked_token1 : access token
            # linked_token2 : (expires at or 0) : refresh token or empty
            my ($expires, $refresh) = split /:/, $r->{linked_token2}, 2;

            if ((not $expires or time + 120 < $expires) and
                not $app->bare_param ('force_refresh')) {
              $json->{access_token} = $r->{linked_token1}
                  if length $r->{linked_token1};
              $json->{expires} = $expires if $expires;
              return;
            }
            
            if (defined $refresh and length $refresh) {
              my $sk_context = $session_row->get ('sk_context');
              my $client_id = $app->config->get ($server->{name} . '.client_id.' . $sk_context) //
                              $app->config->get ($server->{name} . '.client_id');
              my $client_secret = $app->config->get ($server->{name} . '.client_secret.' . $sk_context) //
                                  $app->config->get ($server->{name} . '.client_secret');
              my $url = Web::URL->parse_string
                  (($server->{url_scheme} // 'https') . '://' . $server->{host} . $server->{token_endpoint});
              my $client = Web::Transport::ConnectionClient->new_from_url ($url);
              return $client->request (
                method => 'POST',
                url => $url,
                params => {
                  client_id => $client_id,
                  client_secret => $client_secret,
                  grant_type => 'refresh_token',
                  refresh_token => $refresh,
                },
                #XXX timeout => $server->{timeout} || 10,
              )->then (sub {
                my $res = $_[0];
                die $res unless $res->status == 200;
                my $j = json_bytes2perl $res->content;
                
                $json->{access_token} = $j->{access_token};
                die "No new access token" unless defined $j->{access_token};
                die "No new refresh token" unless defined $j->{refresh_token};

                my $expires = 0+($j->{expires_at} || 0);
                my $token1 = $j->{access_token} // '';
                my $token2 =
                    ($expires) . ':' .
                    ($j->{refresh_token} // '');
                $json->{expires} = $expires;

                my $time = time;
                return $app->db->update ('account_link', {
                  linked_token1 => Dongry::Type->serialize ('text', $token1),
                  linked_token2 => Dongry::Type->serialize ('text', $token2),
                  updated => $time,
                }, where => {
                  account_link_id => $r->{account_link_id},
                }, source_name => 'master')->then (sub {
                  my $v = $_[0];
                  die "Failed to update tokens" unless $v->row_count == 1;
                });
              })->finally (sub {
                return $client->close;
              });
            } # has refresh token
          }
        }
      })->then (sub {
        return $json;
      });
    })->then (sub {
      return $app->send_json ($_[0]);
    }));
  } # /token

  if (@$path == 1 and $path->[0] eq 'keygen') {
    ## /keygen - Generate SSH key pair
    ##
    ## Parameters
    ##
    ##   Operation source parameters.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $server_name = $app->bare_param ('server') // '';
    my $server = $app->config->get_oauth_server ($server_name)
        or return $app->throw_error_json ({reason => 'Bad |server|'});

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      my $account_id = defined $session_row ? $session_row->get ('data')->{account_id} : undef;
      return $app->send_error_json ({reason => 'Not a login user'})
          unless defined $account_id;

      my $key_type = 'rsa';
      return Promise->all ([
        do {
          my $temp = File::Temp->newdir;
          my $dir = Promised::File->new_from_path ("$temp");
          my $private_file_name = "$temp/key";
          my $public_file_name = "$temp/key.pub";
          $dir->mkpath->then (sub {
            my $cmd = Promised::Command->new ([
              'ssh-keygen',
              '-t' => $key_type,
              '-N' => '',
              '-C' => $app->bare_param ('comment') // '',
              '-f' => $private_file_name,
            ]);
            return $cmd->run->then (sub { return $cmd->wait });
          })->then (sub {
            my $result = $_[0];
            die $result unless $result->exit_code == 0;
            return Promise->all ([
              Promised::File->new_from_path ($private_file_name)->read_byte_string,
              Promised::File->new_from_path ($public_file_name)->read_byte_string,
            ]);
          })->then (sub {
            undef $temp;
            my $result = {private => $_[0]->[0], public => $_[0]->[1]};
            return $dir->remove_tree->then (sub { return $result });
          }, sub {
            my $error = $_[0];
            return $dir->remove_tree->then (sub { die $error });
          });
        },
        $app->db->uuid_short (2),
      ])->then (sub {
        my $key = $_[0]->[0];
        my $link_id = '' . $_[0]->[1]->[0];
        my $log_id = '' . $_[0]->[1]->[1];
        my $time = time;
        #      public private
        # dsa     590     668
        # rsa     382    1675
        return $app->db->insert ('account_link', [{
          account_link_id => $link_id,
          account_id => Dongry::Type->serialize ('text', $account_id),
          service_name => Dongry::Type->serialize ('text', $server->{name}),
          created => $time,
          updated => $time,
          linked_id => '',
          linked_key => '',
          linked_name => '',
          linked_email => '',
          linked_token1 => $key->{public},
          linked_token2 => $key->{private},
          linked_data => '{}',
        }], source_name => 'master', duplicate => {
          linked_token1 => $app->db->bare_sql_fragment ('VALUES(linked_token1)'),
          linked_token2 => $app->db->bare_sql_fragment ('VALUES(linked_token2)'),
          updated => $app->db->bare_sql_fragment ('VALUES(updated)'),
        })->then (sub {
          my $data = {
            source_operation => 'keygen',
            service_name => $server->{name},
            key_type => $key_type,
            account_link_id => $link_id,
          };
          my $app_obj = $app->bare_param ('source_data');
          $data->{source_data} = json_bytes2perl $app_obj if defined $app_obj;
          return $app->db->insert ('account_log', [{
            log_id => $log_id,
            account_id => Dongry::Type->serialize ('text', $account_id),
            operator_account_id => Dongry::Type->serialize ('text', $account_id),
            timestamp => $time,
            action => 'link',
            ua => $app->bare_param ('source_ua') // '',
            ipaddr => $app->bare_param ('source_ipaddr') // '',
            data => Dongry::Type->serialize ('json', $data),
          }]); # since R5.9
        });
      });
    })->then (sub {
      return $app->send_json ({});
    });
  } # /keygen

  if (@$path == 2 and $path->[0] eq 'link' and $path->[1] eq 'add') {
    ## /link/add - Insert an account link
    ##
    ## Parameters
    ##
    ##   |account_id|        - The account's ID.
    ##   |sk_context|, |sk|  - The session.  Either session or account ID is
    ##                         required.
    ##   |server|            - The server name.  Required.
    ##   |replace|           = If true, any existing account link with
    ##                         same account ID and server name is replaced.
    ##   |linked_id|         - The account link's linked ID.
    ##   |linked_key|        - The account link's linked key.  Either or
    ##                         both of |linked_id| and |linked_key| is
    ##                         required.
    ##   Other linked_* fields are not supported yet (might be added
    ##   later if necessary).
    ##   Operation source parameters.
    ##
    ## Returns nothing.
    ##
    ## Create an account link.  If there is an existing account link
    ## with same |linked_id| or |linked_key| for the same account and
    ## |server|, it is replaced by the new account link.
    ##
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $server_name = $app->bare_param ('server') // '';
    my $server = $app->config->get_oauth_server ($server_name)
        or return $app->throw_error (400, reason_phrase => 'Bad |server|');
    my $replace = $app->bare_param ('replace');
    
    my $id = $app->bare_param ('account_id');
    my $session_row;
    return ((defined $id ? Promise->resolve ($id) : $class->resume_session ($app)->then (sub {
      $session_row = $_[0];
      return $session_row->get ('data')->{account_id} # or undef
          if defined $session_row;
      return undef;
    }))->then (sub {
      my $account_id = $_[0];
      return $app->throw_error (400, reason_phrase => 'Bad |account_id|')
          unless defined $account_id;
      my $linked_id = $app->bare_param ('linked_id'); # or undef
      my $linked_key = $app->text_param ('linked_key'); # or undef
      return $app->throw_error (400, reason_phrase => 'Bad |linked_key|')
          unless (defined $linked_id or defined $linked_key);
      return $app->db->uuid_short (2)->then (sub {
        my $link_id = '' . $_[0]->[0];
        my $log_id = '' . $_[0]->[1];
        my $time = time;
        return $app->db->transaction->then (sub {
          my $tr = $_[0];
          return Promise->resolve->then (sub {
            return $tr->delete ('account_link', {
              account_id => Dongry::Type->serialize ('text', $account_id),
              service_name => Dongry::Type->serialize ('text', $server->{name}),
            }) if $replace;
          })->then (sub {
            return $tr->insert ('account_link', [{
              account_link_id => $link_id,
              account_id => Dongry::Type->serialize ('text', $account_id),
              service_name => Dongry::Type->serialize ('text', $server->{name}),
              created => $time,
              updated => $time,
              linked_id => $linked_id,
              linked_key => Dongry::Type->serialize ('text', $linked_key),
              linked_name => '',
              linked_email => '',
              linked_token1 => '',
              linked_token2 => '',
              linked_data => '{}',
            }], source_name => 'master', duplicate => 'replace');
          })->then (sub {
            my $data = {
              source_operation => 'link/add',
              service_name => $server->{name},
              linked_id => $linked_id,
              linked_key => $linked_key,
              account_link_id => $link_id,
            };
            $data->{replace} = 1 if $replace;
            my $app_obj = $app->bare_param ('source_data');
            $data->{source_data} = json_bytes2perl $app_obj if defined $app_obj;
            return $tr->insert ('account_log', [{
              log_id => $log_id,
              account_id => Dongry::Type->serialize ('text', $account_id),
              operator_account_id => Dongry::Type->serialize ('text', $account_id),
              timestamp => $time,
              action => 'link',
              ua => $app->bare_param ('source_ua') // '',
              ipaddr => $app->bare_param ('source_ipaddr') // '',
              data => Dongry::Type->serialize ('json', $data),
            }]); # since R5.9
          })->then (sub {
            return $tr->commit;
          });
        });
      });
    })->then (sub {
      return $app->send_json ({});
    }));
  } elsif (@$path == 2 and $path->[0] eq 'link' and $path->[1] eq 'delete') {
    ## /link/delete - Delete an account link
    ##
    ## Parameters
    ##
    ##   |account_id|        - The account's ID.
    ##   |sk_context|, |sk|  - The session.  Either session or account ID is
    ##                         required.
    ##   |server|            - The server name.  Required although redundant.
    ##   |account_link_id|   - The account link's ID.
    ##   |all|               - If true, all account links with same account
    ##                         ID and server name are removed.  Either
    ##                         |account_link_id| or |all| is required.
    ##   |nolast| : Boolean  - If true, the account link is not deleted
    ##                         when it is the last account link with same
    ##                         server name.
    ##   |nolast_server|     - The list of the account link's server names
    ##                         for the purpose of |nolast|'s testing, in
    ##                         addition to |server|.  Zero or more parameters
    ##                         can be specified.
    ##   |with_links| : Boolean - If true, linked email addresses from
    ##                         account links with server |email| (before
    ##                         the deletion) is returned.
    ##   Operation source parameters.
    ##
    ## Returns:
    ##
    ##   |links|
    ##     |account_link_id|
    ##     |linked_email|
    ##
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $server_name = $app->bare_param ('server') // '';
    my $server = $app->config->get_oauth_server ($server_name)
        or return $app->throw_error_json ({reason => 'Bad |server|'});

    my $id = $app->bare_param ('account_id');
    my $result = {};
    my $session_row;
    return ((defined $id ? Promise->resolve ($id) : $class->resume_session ($app)->then (sub {
      $session_row = $_[0];
      return $session_row->get ('data')->{account_id} # or undef
          if defined $session_row;
      return undef;
    }))->then (sub {
      my $id = $_[0];
      return $app->throw_error_json ({reason => 'Bad |account_id|'})
          unless defined $id;
      my $link_id = $app->bare_param ('account_link_id');
      my $all = $app->bare_param ('all');
      my $time = time;
      return $app->throw_error_json ({reason => 'Bad |account_link_id|'})
          if not defined $link_id and not $all or
             $all and defined $link_id;
      return $app->db->transaction->then (sub {
        my $tr = $_[0];
        return Promise->resolve->then (sub {
          return unless $app->bare_param ('with_emails');
          return $tr->select ('account_link', {
            account_id => Dongry::Type->serialize ('text', $id),
            service_name => 'email',
          }, fields => ['account_link_id', 'linked_email']);
        })->then (sub {
          my $v = $_[0];
          if (defined $v) {
            $result->{links} = [map {
              $_->{account_link_id} .= '';
              $_->{linked_email} = Dongry::Type->parse ('text', $_->{linked_email});
              $_;
            } @{$v->all}];
          }
          return unless $app->bare_param ('nolast');
          my $found = {};
          my $nolast_names = [grep { not $found->{$_}++ } @{$app->bare_param_list ('nolast_server')}, Dongry::Type->serialize ('text', $server->{name})];

          return $tr->select ('account_link', {
            account_id => Dongry::Type->serialize ('text', $id),
            service_name => {-in => $nolast_names},
          }, fields => [{-count => undef, as => 'c'}], lock => 'update')->then (sub {
            my $c = ($_[0]->first || {})->{c} || 0;
            if ($c < 2) {
              return $tr->rollback->then (sub {
                return $app->throw_error_json ({reason => 'Last account link'});
              });
            }
          });
        })->then (sub {
          return $tr->execute ('select uuid_short() as `1`', {}, source_name => 'master');
        })->then (sub {
          my $log_id = '' . $_[0]->first->{1};
          my $data = {
            source_operation => 'link/delete',
            service_name => $server->{name},
          };
          my $app_obj = $app->bare_param ('source_data');
          $data->{source_data} = json_bytes2perl $app_obj if defined $app_obj;
          if ($all) {
            $data->{all} = 1;
            return $tr->delete ('account_link', {
              account_id => Dongry::Type->serialize ('text', $id),
              service_name => Dongry::Type->serialize ('text', $server->{name}),
            }, source_name => 'master')->then (sub {
              return $tr->insert ('account_log', [{
                log_id => $log_id,
                account_id => Dongry::Type->serialize ('text', $id),
                operator_account_id => Dongry::Type->serialize ('text', $id),
                timestamp => $time,
                action => 'unlink',
                ua => $app->bare_param ('source_ua') // '',
                ipaddr => $app->bare_param ('source_ipaddr') // '',
                data => Dongry::Type->serialize ('json', $data),
              }]); # since R5.9
            });
          } else {
            $data->{account_link_id} = '' . $link_id;
            return $tr->delete ('account_link', {
              account_id => Dongry::Type->serialize ('text', $id),
              account_link_id => Dongry::Type->serialize ('text', $link_id),
              service_name => Dongry::Type->serialize ('text', $server->{name}),
            }, source_name => 'master')->then (sub {
              return $tr->insert ('account_log', [{
                log_id => $log_id,
                account_id => Dongry::Type->serialize ('text', $id),
                operator_account_id => Dongry::Type->serialize ('text', $id),
                timestamp => $time,
                action => 'unlink',
                ua => $app->bare_param ('source_ua') // '',
                ipaddr => $app->bare_param ('source_ipaddr') // '',
                data => Dongry::Type->serialize ('json', $data),
              }]); # since R5.9
            });
          }
        })->then (sub {
          return $tr->commit;
        });
      });
    })->then (sub {
      return $app->send_json ($result);
    }));
  } elsif (@$path == 2 and $path->[0] eq 'link' and $path->[1] eq 'search') {
    ## /link/search - Search account links
    ##
    ## Parameters
    ##
    ##   |server|            - The server name.  Required.
    ##   |linked_id|         - The account link's linked ID.
    ##   |linked_key|        - The account link's linked key.  Either or
    ##                         both of |linked_id| and |linked_key| is
    ##                         required.
    ##
    ## Returns
    ##   |items|             - An array of account links (fields are
    ##                         restricted to |account_link_id| and
    ##                         |account_id| for now).
    ##
    ## Supports paging.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 50, max_limit => 100);

    my $server_name = $app->bare_param ('server') // '';
    my $server = $app->config->get_oauth_server ($server_name)
        or return $app->throw_error (400, reason_phrase => 'Bad |server|');

    my $linked_id = $app->bare_param ('linked_id'); # or undef
    my $linked_key = $app->text_param ('linked_key'); # or undef
    return $app->throw_error (400, reason_phrase => 'Bad |linked_key|')
        unless (defined $linked_id or defined $linked_key);
    my $where = {
      service_name => $server_name,
      (defined $page->{value} ? (created => $page->{value}) : ()),
    };
    $where->{linked_id} = $linked_id if defined $linked_id;
    $where->{linked_key} = Dongry::Type->serialize ('text', $linked_key)
        if defined $linked_key;
    return $app->db->select ('account_link', $where,
      fields => ['account_id', 'account_link_id', 'created'],
      source_name => 'master',
      offset => $page->{offset}, limit => $page->{limit},
      order => ['created', $page->{order_direction}],
    )->then (sub {
      my $v = $_[0];
      my $items = [map {
        $_->{account_id} .= '';
        $_->{account_link_id} .= '';
        $_;
      } $v->all->to_list];
      my $next_page = next_page $page, $items, 'created';
      return $app->send_json ({
        items => $items,
        %$next_page,
      });
    });
  } # /link/...

  if (@$path == 1 and $path->[0] eq 'info') {
    ## /info - Get the current account of the session
    ##
    ## Parameters
    ##   sk           The |sk| value of the sesion, if available
    ##   context_key  An opaque string identifying the application.
    ##                Required when |group_id| is specified.
    ##   group_id     The group ID.  If specified, properties of group and
    ##                group membership of the account of the session are
    ##                also returned.
    ##   additional_group_id Additional group ID.  Zero or more options
    ##                can be specified.  If specified, group memberships
    ##                of the account of the session for these groups
    ##                are also returned.  Ignored when |group_id| is not
    ##                specified.
    ##   additional_group_data Name of data whose value is an additional
    ##                group ID.  Zero or more options can be specified.
    ##                If specified, group memberships of the account
    ##                of the session for these groups are also returned.
    ##                Ignored when |group_id| is not specified, the
    ##                group data is not loaded by |with_group_data|
    ##                option, there is no such data, or the value is not a
    ##                group ID.
    ##   with_data
    ##   with_group_data Data of the group.  Not applicable to additional
    ##                groups.
    ##   with_group_member_data Data of the group's membership.  Not
    ##                applicable to additional groups.
    ##   with_agm_group_data Data of the additional group members' group's
    ##                data.
    ##
    ## Also, status filters |user_status|, |admin_status|,
    ## |terms_version| with empty prefix are available for account
    ## data.
    ##
    ## Status filters |owner_status| and |admin_status| with prefix
    ## |group_| are available for group and additional group objects.
    ##
    ## Status filters |user_status|, |owner_status|, |member_type|
    ## with prefix |group_membership_| are available for group
    ## membership object.
    ##
    ## Returns
    ##   account_id   The account ID, if there is an account.
    ##   name         The name of the account, if there is an account.
    ##   user_status  The user status of the account, if there is.
    ##   admin_status The admin status of the account, if there is.
    ##   terms_version The terms version of the account, if there is.
    ##   group        The group object, if available.
    ##   group_membership The group membership object, if available.
    ##   login_time : Timestamp? : The last login time of the session,
    ##                             if applicable.
    ##   no_email : Boolean : If true, there is an account but no account
    ##                        link with service name |email|.  Note that
    ##                        the value might be out of sync when modified.
    ##   additional_group_memberships : Object?
    ##     /group_id/  Additional group's membership object, if available.
    ##       group_data  Group data of the membership's group, if applicable.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      my $context_key = $app->bare_param ('context_key');
      my $group_id = $app->bare_param ('group_id');
      my $json = {};
      return Promise->resolve->then (sub {
        return unless defined $group_id;
        return $app->db->select ('group', {
          context_key => $context_key,
          group_id => $group_id,
          (status_filter $app, 'group_', 'admin_status', 'owner_status'),
        }, fields => ['group_id', 'created', 'updated', 'owner_status', 'admin_status'], source_name => 'master')->then (sub {
          my $g = $_[0]->first // return;
          $g->{group_id} .= '';
          $group_id = $g->{group_id};
          $json->{group} = $g;
          return $class->load_data ($app, 'group_', 'group_data', 'group_id', undef, undef, [$json->{group}], 'data');
        });
      })->then (sub {
        my $account_id;
        my $session_data;
        if (defined $session_row) {
          $session_data = $session_row->get ('data');
          $account_id = $session_data->{account_id};
        }
        return unless defined $account_id;
        
        my $st = $app->http->response_timing ("acc");
        return $app->db->select ('account', {
          account_id => Dongry::Type->serialize ('text', $account_id),
          (status_filter $app, '', 'user_status', 'admin_status', 'terms_version'),
        }, source_name => 'master', fields => ['name', 'user_status', 'admin_status', 'terms_version'])->then (sub {
          my $r = $_[0]->first_as_row;
          $st->add;
          return unless defined $r;
          $json->{account_id} = format_id $account_id;
          $json->{name} = $r->get ('name');
          $json->{user_status} = $r->get ('user_status');
          $json->{admin_status} = $r->get ('admin_status');
          $json->{terms_version} = $r->get ('terms_version');
          $json->{login_time} = $session_data->{login_time};
          $json->{no_email} = 1 if $session_data->{no_email};
          
          if (defined $context_key and defined $group_id) {
              my $add_group_ids = $app->bare_param_list
                  ('additional_group_id');
              if (defined $json->{group}) {
                my $add_group_data_names = $app->bare_param_list
                    ('additional_group_data');
                for my $name (@$add_group_data_names) {
                  if (defined $json->{group}->{data}->{$name} and
                      $json->{group}->{data}->{$name} =~ /\A[1-9][0-9]*\z/) {
                    push @$add_group_ids, unpack 'Q', pack 'Q', $json->{group}->{data}->{$name};
                  }
                }
              }
              my $st = $app->http->response_timing ("gr");
              return $app->db->select ('group_member', {
                context_key => $context_key,
                group_id => {-in => [$group_id, @$add_group_ids]},
                account_id => Dongry::Type->serialize ('text', $account_id),
                (status_filter $app, 'group_membership_', 'user_status', 'owner_status', 'member_type'),
              }, fields => [
                'group_id', 'user_status', 'owner_status', 'member_type',
              ], source_name => 'master')->then (sub {
                my $group_id_to_data = {};
                for (@{$_[0]->all}) {
                  $group_id_to_data->{$_->{group_id}} = $_;
                  $_->{group_id} .= '';
                }
                $st->add;
                if (defined $group_id_to_data->{$group_id}) {
                  $json->{group_membership} = $group_id_to_data->{$group_id};
                }
                for (@$add_group_ids) {
                  $json->{additional_group_memberships}->{$_} = $group_id_to_data->{$_}
                      if defined $group_id_to_data->{$_};
                }
              });
            }
          });
      })->then (sub {
        return $class->load_linked ($app => [$json]);
      })->then (sub {
        my $st = $app->http->response_timing ("accd");
        return $class->load_data ($app, '', 'account_data', 'account_id', undef, undef, [$json], 'data')->then (sub {
          $st->add;
        });
      })->then (sub {
        delete $json->{group_membership} if not defined $json->{group};
        return unless defined $json->{group_membership};
        my $st = $app->http->response_timing ("grmd");
        return $class->load_data ($app, 'group_member_', 'group_member_data', 'group_id', 'account_id', $json->{account_id}, [$json->{group_membership}], 'data')->then (sub {
          $st->add;
        });
      })->then (sub {
        my $st = $app->http->response_timing ("grd");
        return $class->load_data ($app, 'agm_group_', 'group_data', 'group_id', undef, undef, [values %{$json->{additional_group_memberships} or {}}], 'group_data')->then (sub {
          $st->add;
        });
      })->then (sub {
        return $app->send_json ($json);
      });
    });
  } # /info

  if (@$path == 1 and $path->[0] eq 'profiles') {
    ## /profiles - Account data
    ##
    ## Parameters
    ##   account_id (0..)   Account IDs
    ##   with_data
    ##   with_linked
    ##   with_icons
    ##
    ## Also, status filters |user_status|, |admin_status|,
    ## |terms_version| with empty prefix are available.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $account_ids = $app->bare_param_list ('account_id')->to_a;
    $_ = unpack 'Q', pack 'Q', $_ for @$account_ids;
    return ((@$account_ids ? $app->db->select ('account', {
      account_id => {-in => $account_ids},
      (status_filter $app, '', 'user_status', 'admin_status', 'terms_version'),
    }, source_name => 'master', fields => ['account_id', 'name'])->then (sub {
      return $_[0]->all_as_rows->to_a;
    }) : Promise->resolve ([]))->then (sub {
      return $class->load_linked ($app, [map {
        +{
          account_id => format_id $_->get ('account_id'),
          name => $_->get ('name'),
        };
      } @{$_[0]}]);
    })->then (sub {
      return $class->load_data ($app, '', 'account_data', 'account_id', undef, undef, $_[0], 'data');
    })->then (sub {
      return $class->load_icons ($app, 1, 'account_id', $_[0]);
    })->then (sub {
      return $app->send_json ({
        accounts => {map { $_->{account_id} => $_ } @{$_[0]}},
      });
    }));
  } # /profiles

  if (@$path == 1 and $path->[0] eq 'data') {
    ## /data - Account data
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      my $account_id = defined $session_row ? $session_row->get ('data')->{account_id} : undef;

      return $app->send_error_json ({reason => 'Not a login user'})
          unless defined $account_id;

      my $names = $app->text_param_list ('name');
      my $values = $app->text_param_list ('value');
      my @data;
      for (0..$#$names) {
        push @data, {
          account_id => Dongry::Type->serialize ('text', $account_id),
          key => Dongry::Type->serialize ('text', $names->[$_]),
          value => Dongry::Type->serialize ('text', $values->[$_]),
          created => time,
          updated => time,
        } if defined $values->[$_];
      }
      if (@data) {
        return $app->db->insert ('account_data', \@data, duplicate => {
          value => $app->db->bare_sql_fragment ('VALUES(`value`)'),
          updated => $app->db->bare_sql_fragment ('VALUES(updated)'),
        })->then (sub {
          return $app->send_json ({});
        });
      } else {
        return $app->send_json ({});
      }
    });
  } # /data

  if (@$path == 1 and $path->[0] eq 'agree') {
    ## /agree - Agree with terms
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      my $account_id = defined $session_row ? Dongry::Type->serialize ('text', $session_row->get ('data')->{account_id}) : undef;
      return $app->send_error_json ({reason => 'Not a login user'})
          unless defined $account_id;

      my $version = 0+($app->bare_param ('version') || 0);
      $version = 255 if $version > 255;
      my $dg = $app->bare_param ('downgrade');
      return Promise->all ([
        $app->db->execute ('UPDATE `account` SET `terms_version` = :version WHERE `account_id` = :account_id'.($dg?'':' AND `terms_version` < :version'), {
          account_id => $account_id,
          version => $version,
        }, source_name => 'master'),
        $app->db->uuid_short (1),
      ])->then (sub {
        die "UPDATE failed" unless $_[0]->[0]->row_count <= 1;
        my $data = {
          source_operation => 'agree',
          version => $version,
        };
        my $app_obj = $app->bare_param ('source_data');
        $data->{source_data} = json_bytes2perl $app_obj if defined $app_obj;
        return $app->db->insert ('account_log', [{
          log_id => $_[0]->[1]->[0],
          account_id => $account_id,
          operator_account_id => $account_id,
          timestamp => time,
          action => 'agree',
          ua => $app->bare_param ('source_ua') // '',
          ipaddr => $app->bare_param ('source_ipaddr') // '',
          data => Dongry::Type->serialize ('json', $data),
        }]);
      })->then (sub {
        return $app->send_json ({});
      });
    });
  } # /agree

  if (@$path == 1 and $path->[0] eq 'search') {
    ## /search - User search
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $q = $app->text_param ('q');
    my $q_like = Dongry::Type->serialize ('text', '%' . (like $q) . '%');

    # XXX better full-text search
    return (((length $q) ? $app->db->execute ('SELECT account_id,service_name,linked_name,linked_id,linked_key FROM account_link WHERE linked_id like :linked_id or linked_key like :linked_key or linked_name like :linked_name LIMIT :limit', {
      linked_id => $q_like,
      linked_key => $q_like,
      linked_name => $q_like,
      limit => $app->bare_param ('per_page') || 20,
    }, source_name => 'master', table_name => 'account_link')->then (sub {
      return $_[0]->all_as_rows;
    }) : Promise->resolve ([]))->then (sub {
      my $accounts = {};
      for my $row (@{$_[0]}) {
        my $v = {};
        for (qw(id key name)) {
          my $x = $row->get ('linked_' . $_);
          $v->{$_} = $x if length $x;
        }
        my $aid = $row->get ('account_id');
        $accounts->{$aid}->{services}->{$row->get ('service_name')} = $v;
        $accounts->{$aid}->{account_id} = format_id $aid;
      }
      # XXX filter by account.user_status && account.admin_status
      return $app->send_json ({accounts => $accounts});
    }));
  } # /search

  if (@$path == 2 and $path->[0] eq 'log' and $path->[1] eq 'get') {
    ## /log/get - Get account logs
    ##
    ## Parameters
    ##
    ##   |use_sk|            - If true, |sk| is used to specify the account
    ##                         ID of the logs.
    ##   |log_id|            - The log ID of the log.
    ##   |account_id|        - The account ID of the logs.
    ##   |operator_account_id| - The operator account ID of the logs.
    ##   |ipaddr|            - The IP address of the logs.
    ##   |action|            - The action of the logs.
    ##   At least one of these six groups of parameters is required.
    ##
    ##   |sk|, |sk_context|, |sk_max_age|
    ##
    ## Returns
    ##   |items|             - An array of logs.
    ##
    ## Supports paging.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 50, max_limit => 100);
    my $where = {};
    return Promise->resolve->then (sub {
      for my $key (qw(account_id operator_account_id ipaddr
                      action log_id)) {
        $where->{$key} = $app->bare_param ($key);
        delete $where->{$key} if not defined $where->{$key};
      }
      if ($app->bare_param ('use_sk')) {
        return $app->throw_error
            (400, reason_phrase => 'Both |sk| and |account_id| is specified')
            if defined $app->bare_param ('account_id');
        return $class->resume_session ($app)->then (sub {
          my $session_row = $_[0];
          $where->{account_id} = $session_row->get ('data')->{account_id} # or undef
              if defined $session_row;
          $where->{account_id} = Dongry::Type->serialize ('text', $where->{account_id})
              if defined $where->{account_id};
        });
      }
    })->then (sub {
      return [] if not defined $where->{account_id} and
          $app->bare_param ('use_sk');
      return $app->throw_error (400, reason_phrase => 'No params')
          unless keys %$where;

      $where->{timestamp} = $page->{value} if defined $page->{value};

      return $app->db->select (
        'account_log', $where,
        fields => ['account_id', 'operator_account_id', 'ipaddr',
                   'action', 'log_id', 'ua', 'timestamp', 'data'],
        source_name => 'master',
        offset => $page->{offset}, limit => $page->{limit},
        order => ['timestamp', $page->{order_direction}],
      )->then (sub {
        my $v = $_[0];
        my $items = [map {
          $_->{account_id} .= '';
          $_->{operator_account_id} .= '';
          $_->{log_id} .= "";
          $_->{data} = Dongry::Type->parse ('json', $_->{data});
          $_;
        } $v->all->to_list];
        return $items;
      });
    })->then (sub {
      my $items = $_[0];
      my $next_page = next_page $page, $items, 'timestamp';
      return $app->send_json ({
        items => $items,
        %$next_page,
      });
    });
  } # /log/get

  if (@$path == 1 and $path->[0] eq 'robots.txt') {
    # /robots.txt
    return $app->send_plain_text ("User-agent: *\nDisallow: /");
  }

  return $app->send_error (404);
} # main

sub resume_session ($$;$) {
  my ($class, $app, $tr) = @_;
  my $sk = $app->bare_param ('sk') // '';
  return (length $sk ? ($tr // $app->db)->select ('session', {
    sk => $sk,
    sk_context => $app->bare_param ('sk_context') // '',
    created => {'>', time - $MaxSessionTimeout},
  }, source_name => 'master', lock => (defined $tr ? 'update' : undef))->then (sub {
    my $acc = $_[0]->first_as_row; # or undef

    my $ma = $app->bare_param ('sk_max_age');
    if ($ma) {
      my $data = $acc->get ('data');
      unless (($data->{login_time} || 0) + $ma > time) {
        return undef;
      }
    }
    
    return $acc;
  }) : Promise->resolve (undef));
} # resume_session

sub delete_old_sessions ($$) {
  return $_[1]->db->execute ('DELETE FROM `session` WHERE created < ?', {
    created => time - $MaxSessionTimeout,
  });
} # delete_old_sessions

sub get_resource_owner_profile ($$%) {
  my ($class, $app, %args) = @_;
  my $server = $args{server} or die;
  my $service = $server->{name};
  my $session_data = $args{session_data} or die;
  return unless defined $server->{profile_endpoint};

  my %param;
  if ($server->{auth_scheme} eq 'header') {
    $param{headers}->{Authorization} = 'Bearer ' . $session_data->{$service}->{access_token};
  } elsif ($server->{auth_scheme} eq 'query') {
    $param{params}->{access_token} = $session_data->{$service}->{access_token};
  } elsif ($server->{auth_scheme} eq 'token') {
    $param{headers}->{Authorization} = 'token ' . $session_data->{$service}->{access_token};
  } elsif ($server->{auth_scheme} eq 'oauth1') {
    my $client_id = $app->config->get ($server->{name} . '.client_id.' . $args{sk_context}) //
        $app->config->get ($server->{name} . '.client_id');
    my $client_secret = $app->config->get ($server->{name} . '.client_secret.' . $args{sk_context}) //
        $app->config->get ($server->{name} . '.client_secret');
    
    $param{oauth1} = [$client_id, $client_secret,
                      @{$session_data->{$service}->{access_token}}];
    $param{params}->{user_id} = $session_data->{$service}->{user_id}
        if $server->{name} eq 'twitter';
  }
  
  my $url = Web::URL->parse_string
      ((($server->{url_scheme} // 'https') . '://' . ($server->{profile_host} // $server->{host}) . $server->{profile_endpoint}));
  my $client = Web::Transport::BasicClient->new_from_url ($url);
  return $client->request (
    url => $url,
    %param,
    last_resort_timeout => $server->{timeout} || 30,
  )->then (sub {
    my $res = $_[0];
    die $res unless $res->status == 200;
    return json_bytes2perl $res->body_bytes;
  })->then (sub {
    my $json = $_[0];
    $session_data->{$service}->{profile_id} = $json->{$server->{profile_id_field}}
        if defined $server->{profile_id_field};
    $session_data->{$service}->{profile_key} = $json->{$server->{profile_key_field}}
        if defined $server->{profile_key_field};
    $session_data->{$service}->{profile_name} = $json->{$server->{profile_name_field}}
        if defined $server->{profile_name_field};
    $session_data->{$service}->{profile_email} = $json->{$server->{profile_email_field}}
        if defined $server->{profile_email_field};
    for (keys %{$server->{profile_data_fields} or {}}) {
      my $v = $server->{profile_data_fields}->{$_};
      $session_data->{$service}->{linked_data}->{$_} = $json->{$v}
          if defined $json->{$v};
    }
    if (defined $session_data->{$service}->{profile_email} and
        defined $server->{profile_data_fields}->{email_verified} and
        ($session_data->{$service}->{linked_data}->{email_verified} // '') ne 'true') {
      delete $session_data->{$service}->{linked_data}->{profile_email};
    }
  });
} # get_resource_owner_profile

sub login_account ($$$) {
  my ($class, $app, $server, $session_data) = @_;
  my $service = $server->{name};

  return $app->throw_error (400, reason_phrase => 'Non-loginable |service|')
      unless defined $server->{linked_id_field};

  my $link = {name => $session_data->{$service}->{$server->{linked_name_field} // ''},
              id => $session_data->{$service}->{$server->{linked_id_field} // ''},
              key => $session_data->{$service}->{$server->{linked_key_field} // ''},
              email => $session_data->{$service}->{$server->{linked_email_field} // ''},
              data => $session_data->{$service}->{linked_data} || {}};

  return $app->throw_error (400, reason_phrase => 'Non-loginable server account')
      unless defined $link->{id} and length $link->{id};

  return $app->db->execute ('SELECT account_link_id, account_id FROM account_link WHERE service_name = ? AND linked_id = ?', {
    service_name => Dongry::Type->serialize ('text', $service),
    linked_id => Dongry::Type->serialize ('text', $link->{id}),
  }, source_name => 'master')->then (sub {
    my $links = $_[0]->all;
    # XXX filter by account status?
    $links = [$links->[0]] if @$links; # XXX
    my $token1 = '';
    my $token2 = '';
    if (defined $server->{temp_endpoint}) { # OAuth 1.0
      my $at = $session_data->{$service}->{access_token};
      ($token1, $token2) = @$at if defined $at and ref $at eq 'ARRAY' and @$at == 2;
    } else {
      my $service_data = $session_data->{$service};
      $token1 = $service_data->{access_token} // '';
      $token2 =
          (0+($service_data->{expires_at} || 0)) . ':' .
          ($service_data->{refresh_token} // '');
    }
    if (@$links == 0) { # new account
      $session_data->{no_email} = 1;
      my @log;
      my $log_data = {
        source_operation => $session_data->{action}->{operation},
      };
      my $app_obj = $app->bare_param ('source_data');
      $log_data->{source_data} = json_bytes2perl $app_obj if defined $app_obj;
      my $log_cols = {
        ua => $app->bare_param ('source_ua') // '',
        ipaddr => $app->bare_param ('source_ipaddr') // '',
      };
      return $app->db->uuid_short (6)->then (sub {
        my $account_id = '' . $_[0]->[0];
        my $link_id1 = '' . $_[0]->[1];
        my $link_id2 = '' . $_[0]->[2];
        my $log_id1 = '' . $_[0]->[1];
        my $log_id2 = '' . $_[0]->[2];
        my $log_id3 = '' . $_[0]->[3];
        my $time = time;
        my $account = {account_id => $account_id,
                       user_status => 1, admin_status => 1,
                       terms_version => 0};
        my $name = $link->{name};
        $name = $account_id unless defined $name and length $name;
        return $app->db->execute ('INSERT INTO account (account_id, created, user_status, admin_status, terms_version, name) VALUES (:account_id, :created, :user_status, :admin_status, :terms_version, :name)', {
          created => $time,
          %$account,
          name => Dongry::Type->serialize ('text', $name),
        }, source_name => 'master', table_name => 'account')->then (sub {
          push @log, {
            log_id => $log_id1,
            account_id => $account_id,
            operator_account_id => $account_id,
            timestamp => $time,
            action => 'create',
            %$log_cols,
            data => Dongry::Type->serialize ('json', $log_data),
          };
          return $app->db->execute ('INSERT INTO account_link (account_link_id, account_id, service_name, created, updated, linked_name, linked_id, linked_key, linked_token1, linked_token2, linked_email, linked_data) VALUES (:account_link_id, :account_id, :service_name, :created, :updated, :linked_name, :linked_id, :linked_key:nullable, :linked_token1, :linked_token2, :linked_email, :linked_data)', {
            account_link_id => $link_id1,
            account_id => $account_id,
            service_name => Dongry::Type->serialize ('text', $server->{name}),
            created => $time,
            updated => $time,
            linked_name => Dongry::Type->serialize ('text', $link->{name} // ''),
            linked_id => Dongry::Type->serialize ('text', $link->{id}),
            linked_key => Dongry::Type->serialize ('text', $link->{key}), # or undef
            linked_email => Dongry::Type->serialize ('text', $link->{email} // ''),
            linked_token1 => Dongry::Type->serialize ('text', $token1),
            linked_token2 => Dongry::Type->serialize ('text', $token2),
            linked_data => Dongry::Type->serialize ('json', $link->{data}),
          }, source_name => 'master', table_name => 'account_link')->then (sub {
            push @log, {
              log_id => $log_id2,
              account_id => $account_id,
              operator_account_id => $account_id,
              timestamp => $time,
              action => 'link',
              %$log_cols,
              data => Dongry::Type->serialize ('json', {
                service_name => $server->{name},
                linked_name => $link->{name}, # or undef
                linked_id => $link->{id}, # or undef
                linked_key => $link->{key}, # or undef
                linked_email => $link->{email}, # or undef
                account_link_id => $link_id1,
                %$log_data,
              }),
            };
            my $account_link = {account_link_id => $link_id1};
            return [$account, $account_link];
          });
        })->then (sub {
          my $return = $_[0];
          return $return unless $session_data->{action}->{create_email_link};
          my $addr = $link->{email} // '';
          return $return unless $addr =~ /\A[\x21-\x3F\x41-\x7E]+\@[\x21-\x3F\x41-\x7E]+\z/;
          my $email_id = sha1_hex $addr;
          delete $session_data->{no_email};
          return $app->db->insert ('account_link', [{
            account_link_id => $link_id2,
            account_id => $account_id,
            service_name => 'email',
            created => $time,
            updated => $time,
            linked_name => '',
            linked_id => $email_id,
            linked_key => undef,
            linked_email => Dongry::Type->serialize ('text', $addr),
            linked_token1 => '',
            linked_token2 => '',
            linked_data => '{}',
          }], source_name => 'master', duplicate => 'replace')->then (sub {
            push @log, {
              log_id => $log_id3,
              account_id => $account_id,
              operator_account_id => $account_id,
              timestamp => $time,
              action => 'link',
              %$log_cols,
              data => Dongry::Type->serialize ('json', {
                service_name => 'email',
                linked_id => $email_id,
                linked_email => $addr,
                account_link_id => $link_id2,
                %$log_data,
              }),
            };
            return $return;
          });
        });
      })->then (sub {
        my $return = $_[0];
        return $app->db->insert ('account_log', \@log)->then (sub { $return });
      });
    } elsif (@$links == 1) { # existing account
      my $time = time;
      my $account_id = $links->[0]->{account_id};
      my $name = $account_id;
      $name = $link->{name} if defined $link->{name} and length $link->{name};
      return Promise->all ([
        $app->db->execute ('UPDATE account SET name = ? WHERE account_id = ?', {
          name => Dongry::Type->serialize ('text', $name),
          account_id => $account_id,
        }, source_name => 'master')->then (sub {
          return $app->db->execute ('SELECT account_id,user_status,admin_status,terms_version FROM account WHERE account_id = ?', {
            account_id => $account_id,
          }, source_name => 'master', table_name => 'account');
        }),
        $app->db->execute ('UPDATE account_link SET linked_name = ?, linked_id = ?, linked_key = :linked_key:nullable, linked_token1 = ?, linked_token2 = ?, linked_email = ?, linked_data = ?, updated = ? WHERE account_link_id = ? AND account_id = ?', {
          account_link_id => $links->[0]->{account_link_id},
          account_id => $account_id,
          linked_name => Dongry::Type->serialize ('text', $link->{name} // ''),
          linked_id => Dongry::Type->serialize ('text', $link->{id}),
          linked_key => Dongry::Type->serialize ('text', $link->{key}), # or undef
          linked_token1 => Dongry::Type->serialize ('text', $token1),
          linked_token2 => Dongry::Type->serialize ('text', $token2),
          linked_email => Dongry::Type->serialize ('text', $link->{email} // ''),
          linked_data => Dongry::Type->serialize ('json', $link->{data}),
          updated => $time,
          ## Note that no `account_log` is inserted when linked_* is
          ## updated here.
        }, source_name => 'master'),
        $app->db->select ('account_link', {
          account_id => $account_id,
          service_name => 'email',
        }, limit => 1, fields => ['account_link_id'], source_name => 'master')->then (sub {
          delete $session_data->{no_email};
          $session_data->{no_email} = 1 if not defined $_[0]->first;
        }),
      ])->then (sub {
        return [$_[0]->[0]->first, {account_link_id => $links->[0]->{account_link_id}}];
      });
    } else { # multiple account links
      die "XXX Not implemented yet";
    }
  })->then (sub {
    my ($account, $account_link) = @{$_[0]};
    unless ($account->{user_status} == 1) {
      die "XXX Disabled account";
    }
    unless ($account->{admin_status} == 1) {
      die "XXX Account suspended";
    }
    $session_data->{account_id} = format_id $account->{account_id};
  });
} # login_account

sub link_account ($$$) {
  my ($class, $app, $server, $session_data) = @_;
  my $service = $server->{name};

  my $link = {name => $session_data->{$service}->{$server->{linked_name_field} // ''},
              id => $session_data->{$service}->{$server->{linked_id_field} // ''},
              key => $session_data->{$service}->{$server->{linked_key_field} // ''},
              email => $session_data->{$service}->{$server->{linked_email_field} // ''},
              data => $session_data->{$service}->{linked_data} || {}};

  my $token1 = '';
  my $token2 = '';
  if (defined $server->{temp_endpoint}) { # OAuth 1.0
    my $at = $session_data->{$service}->{access_token};
    ($token1, $token2) = @$at if defined $at and ref $at eq 'ARRAY' and @$at == 2;
  } else {
    my $service_data = $session_data->{$service};
    $token1 = $service_data->{access_token} // '';
    $token2 =
        (0+($service_data->{expires_at} || 0)) . ':' .
        ($service_data->{refresh_token} // '');
  }

  return $app->db->uuid_short (2)->then (sub {
    my $link_id = ''. $_[0]->[0];
    my $log_id = ''. $_[0]->[1];
    my $time = time;
    return $app->db->insert ('account_link', [{
      account_link_id => $link_id,
      account_id => Dongry::Type->serialize ('text', $session_data->{account_id}),
      service_name => Dongry::Type->serialize ('text', $server->{name}),
      created => $time,
      updated => $time,
      linked_name => Dongry::Type->serialize ('text', $link->{name} // ''),
      linked_id => Dongry::Type->serialize ('text', $link->{id}), # or undef
      linked_key => Dongry::Type->serialize ('text', $link->{key}), # or undef
      linked_email => Dongry::Type->serialize ('text', $link->{email} // ''),
      linked_token1 => Dongry::Type->serialize ('text', $token1),
      linked_token2 => Dongry::Type->serialize ('text', $token2),
      linked_data => Dongry::Type->serialize ('json', $link->{data}),
    }], source_name => 'master', duplicate => {
      updated => $app->db->bare_sql_fragment ('VALUES(updated)'),
      linked_name => $app->db->bare_sql_fragment ('VALUES(linked_name)'),
      linked_id => $app->db->bare_sql_fragment ('VALUES(linked_id)'),
      linked_key => $app->db->bare_sql_fragment ('VALUES(linked_key)'),
      linked_email => $app->db->bare_sql_fragment ('VALUES(linked_email)'),
      linked_token1 => $app->db->bare_sql_fragment ('VALUES(linked_token1)'),
      linked_token2 => $app->db->bare_sql_fragment ('VALUES(linked_token2)'),
      linked_data => $app->db->bare_sql_fragment ('VALUES(linked_data)'),
    })->then (sub {
      my $data = {
        source_operation => $session_data->{action}->{operation},
        service_name => $server->{name},
        linked_name => $link->{name}, # or undef
        linked_key => $link->{key}, # or undef
        linked_email => $link->{email}, # or undef
        account_link_id => $link_id,
      };
      $data->{linked_id} = '' . $link->{id} if defined $link->{id};
      my $app_obj = $app->bare_param ('source_data');
      $data->{source_data} = json_bytes2perl $app_obj if defined $app_obj;
      return $app->db->insert ('account_log', [{
        log_id => $log_id,
        account_id => Dongry::Type->serialize ('text', $session_data->{account_id}),
        operator_account_id => Dongry::Type->serialize ('text', $session_data->{account_id}),
        timestamp => $time,
        action => 'link',
        ua => $app->bare_param ('source_ua') // '',
        ipaddr => $app->bare_param ('source_ipaddr') // '',
        data => Dongry::Type->serialize ('json', $data),
      }]); # since R5.9
    });
  });
} # link_account

## An account link object:
##
##   ...
##   |account_link_id|   The ID of the account link object.
sub load_linked ($$$) {
  my ($class, $app, $items) = @_;

  my $account_id_to_json = {};
  my @account_id = map {
    $account_id_to_json->{$_->{account_id}} = $_;
    Dongry::Type->serialize ('text', $_->{account_id});
  } grep { defined $_->{account_id} } @$items;
  return $items unless @account_id;

  my $with = {};
  for (@{$app->bare_param_list ('with_linked')}) {
    $with->{$_} = 1;
  }
  my @field;
  push @field, 'linked_id'; #if delete $with->{id}; ## Used as hash key
  push @field, 'linked_key' if delete $with->{key};
  push @field, 'linked_name' if delete $with->{name};
  push @field, 'linked_email' if delete $with->{email};
  if (keys %$with) {
    push @field, 'linked_data';
  }
  return $items unless @field;
  push @field,
      qw(service_name account_id account_link_id created updated);

  return $app->db->select ('account_link', {
    account_id => {-in => \@account_id},
  }, fields => \@field, source_name => 'master')->then (sub {
    for (@{$_[0]->all}) {
      my $json = $account_id_to_json->{$_->{account_id}};
      my $link = $json->{links}->{$_->{service_name}, $_->{linked_id} // ''} ||= {};
      #my $server = $app->config->get_oauth_server ($_->{service_name}) || {};
      $link->{service_name} = $_->{service_name};
      $link->{id} = ''.$_->{linked_id}
          if defined $_->{linked_id} and length $_->{linked_id};
      $link->{key} = Dongry::Type->parse ('text', $_->{linked_key})
          if defined $_->{linked_key} and length $_->{linked_key};
      $link->{name} = Dongry::Type->parse ('text', $_->{linked_name})
          if defined $_->{linked_name} and length $_->{linked_name};
      $link->{email} = Dongry::Type->parse ('text', $_->{linked_email})
          if defined $_->{linked_email} and length $_->{linked_email};
      if (defined $_->{linked_data}) {
        my $data = Dongry::Type->parse ('json', $_->{linked_data});
        for (keys %$with) {
          $link->{$_} = $data->{$_} if defined $data->{$_};
        }
      }
      $link->{account_link_id} = ''.$_->{account_link_id};
      $link->{created} = $_->{created};
      $link->{updated} = $_->{updated};
    }
    return $items;
  });
} # load_linked

sub load_data ($$$$$$$$$) {
  my ($class, $app, $prefix, $table_name, $id_key, $id2_key, $id2_value, $items, $item_key) = @_;

  my $id_to_json = {};
  my @id = map {
    $id_to_json->{$_->{$id_key}} = $_;
    Dongry::Type->serialize ('text', $_->{$id_key});
  } grep { defined $_->{$id_key} } @$items;
  return Promise->resolve ($items) unless @id;

  my @field = map { Dongry::Type->serialize ('text', $_) } $app->text_param_list ('with_'.$prefix.'data')->to_list;
  return Promise->resolve ($items) unless @field;

  return $app->db->select ($table_name, {
    $id_key => {-in => \@id},
    (defined $id2_key ? ($id2_key => Dongry::Type->serialize ('text', $id2_value)) : ()),
    key => {-in => \@field},
  }, source_name => 'master')->then (sub {
    for (@{$_[0]->all}) {
      my $json = $id_to_json->{$_->{$id_key}};
      $json->{$item_key}->{$_->{key}} = Dongry::Type->parse ('text', $_->{value})
          if defined $_->{value} and length $_->{value};
    }
    return $items;
  });
} # load_data

sub load_icons ($$$$$) {
  my ($class, $app, $target_type, $id_key, $items) = @_;
  my $context_keys = $app->bare_param_list ('with_icon');
  return $items unless @$context_keys;
  
  my $id_to_json = {};
  my @id = map {
    $id_to_json->{$_->{$id_key}} = $_;
    $_->{icons} ||= {};
    Dongry::Type->serialize ('text', $_->{$id_key});
  } grep { defined $_->{$id_key} } @$items;
  return $items unless @id;

  return $app->db->select ('icon', {
    context_key => {-in => $context_keys},
    target_type => $target_type,
    target_id => {-in => \@id},
    admin_status => 1, # open
  }, source_name => 'master', fields => [
    'context_key', 'target_id', 'url', 'updated',
  ])->then (sub {
    for (@{$_[0]->all}) {
      my $json = $id_to_json->{$_->{target_id}};
      my $cfg = sub {
        my $n = $_[0];
        return $app->config->get ($n . '.' . $_->{context_key}) //
               $app->config->get ($n); # or undef
      }; # $cfg
      $json->{icons}->{$_->{context_key}} = $cfg->('s3_image_url_prefix') . $_->{url} . '?' . $_->{updated}
          if defined $_->{url} and length $_->{url};
    }
    return $items;
  });
} # load_icons

sub group ($$$) {
  my ($class, $app, $path) = @_;

  if (@$path == 2 and $path->[1] eq 'create') {
    ## /group/create - create a group
    ##
    ## With
    ##   context_key    An opaque string identifying the application.  Required.
    ##   owner_status  A 7-bit positive integer of the group's |owner_status|.
    ##                 Default is 1.
    ##   admin_status  A 7-bit positive integer of the group's |admin_status|.
    ##                 Default is 1.
    ##
    ## Returns
    ##   context_key    Same as |context_key|, for convenience.
    ##   group_id      A 64-bit non-negative integer identifying the group.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $context_key = $app->bare_param ('context_key')
        // return $app->throw_error (400, reason_phrase => 'No |context_key|');
    return $app->db->execute ('select uuid_short() as uuid', undef, source_name => 'master')->then (sub {
      my $group_id = $_[0]->first->{uuid};
      my $time = time;
      return $app->db->insert ('group', [{
        context_key => $context_key,
        group_id => $group_id,
        created => $time,
        updated => $time,
        owner_status => $app->bare_param ('owner_status') // 1, # open
        admin_status => $app->bare_param ('admin_status') // 1, # open
      }])->then (sub {
        return $app->send_json ({
          context_key => $context_key,
          group_id => ''.$group_id,
        });
      });
    });
  } # /group/create

  if (@$path == 2 and $path->[1] eq 'data') {
    ## /group/data - Write group data
    ##
    ## With
    ##   context_key    An opaque string identifying the application.  Required.
    ##   group_id    The group ID.  Required.
    ##   name (0+)   The keys of data pairs.  A key is an ASCII string.
    ##   value (0+)  The values of data pairs.  There must be same number
    ##               of |value|s as |name|s.  A value is a Unicode string.
    ##               An empty string is equivalent to missing.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $group_id = $app->bare_param ('group_id')
        or return $app->throw_error (400, reason_phrase => 'Bad |group_id|');
    return $app->db->select ('group', {
      context_key => $app->bare_param ('context_key'),
      group_id => $group_id,
    }, fields => ['group_id'], source_name => 'master')->then (sub {
      my $x = ($_[0]->first or {})->{group_id};
      return $app->throw_error (404, reason_phrase => '|group_id| not found')
          unless $x and $x eq $group_id;

      my $time = time;
      my $names = $app->text_param_list ('name');
      my $values = $app->text_param_list ('value');
      my @data;
      for (0..$#$names) {
        push @data, {
          group_id => $group_id,
          key => Dongry::Type->serialize ('text', $names->[$_]),
          value => Dongry::Type->serialize ('text', $values->[$_]),
          created => $time,
          updated => $time,
        } if defined $values->[$_];
      }
      if (@data) {
        return $app->db->insert ('group_data', \@data, duplicate => {
          value => $app->db->bare_sql_fragment ('VALUES(`value`)'),
          updated => $app->db->bare_sql_fragment ('VALUES(`updated`)'),
        });
      }
    })->then (sub {
      return $app->send_json ({});
    });
  } # /group/data

  if (@$path == 2 and $path->[1] eq 'touch') {
    ## /group/touch - Update the timestamp of a group
    ##
    ## With
    ##   context_key   An opaque string identifying the application.
    ##                 Required.
    ##   group_id      The group ID.  Required.
    ##   timestamp     The group's updated's new value.  Defaulted to "now".
    ##   force         If true, the group's updated is set to the new
    ##                 value even if it is less than the current value.
    ##
    ## Returns
    ##   changed       If a group is updated, |1|.  Otherwise, |0|.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $time = 0+$app->bare_param ('timestamp') || time;
    my $where = {
      context_key => $app->bare_param ('context_key'),
      group_id => $app->bare_param ('group_id'),
    };
    $where->{updated} = {'<', $time} unless $app->bare_param ('force');
    return $app->db->update ('group', {
      updated => $time,
    }, where => $where)->then (sub {
      my $result = $_[0];
      return $app->send_json ({changed => $result->row_count});
    });
  } # /group/touch

  if (@$path == 2 and $path->[1] eq 'owner_status') {
    ## /group/owner_status - Set the |owner_status| of the group
    ##
    ## With
    ##   context_key    An opaque string identifying the application.  Required.
    ##   group_id      The group ID.  Required.
    ##   owner_status  The new |owner_status| value.  A 7-bit positive integer.
    ##                 Required.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $time = time;
    my $os = $app->bare_param ('owner_status')
        or return $app->throw_error (400, reason_phrase => 'Bad |owner_status|');
    return $app->db->update ('group', {
      owner_status => $os,
      updated => $time,
    }, where => {
      context_key => $app->bare_param ('context_key'),
      group_id => $app->bare_param ('group_id'),
    })->then (sub {
      my $result = $_[0];
      return $app->throw_error (404, reason_phrase => 'Group not found')
          unless $result->row_count == 1;
      return $app->send_json ({});
    });
  } # /group/owner_status

  if (@$path == 2 and $path->[1] eq 'admin_status') {
    ## /group/admin_status - Set the |admin_status| of the group
    ##
    ## With
    ##   context_key    An opaque string identifying the application.  Required.
    ##   group_id      The group ID.  Required.
    ##   admin_status  The new |admin_status| value.  A 7-bit positive integer.
    ##                 Required.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $time = time;
    my $as = $app->bare_param ('admin_status')
        or return $app->throw_error (400, reason_phrase => 'Bad |admin_status|');
    return $app->db->update ('group', {
      admin_status => $as,
      updated => $time,
    }, where => {
      context_key => $app->bare_param ('context_key'),
      group_id => $app->bare_param ('group_id'),
    })->then (sub {
      my $result = $_[0];
      return $app->throw_error (404, reason_phrase => 'Group not found')
          unless $result->row_count == 1;
      return $app->send_json ({});
    });
  } # /group/admin_status

  if (@$path == 2 and $path->[1] eq 'profiles') {
    ## /group/profiles - Get group data
    ##
    ## With
    ##   context_key    An opaque string identifying the application.  Required.
    ##   group_id (0..)      Group IDs
    ##   with_data
    ##   with_icons
    ##
    ## Also, status filters |owner_status| and |admin_status| with
    ## empty prefix are available.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $group_ids = $app->bare_param_list ('group_id')->to_a;
    $_ = unpack 'Q', pack 'Q', $_ for @$group_ids;
    return Promise->resolve->then (sub {
      return [] unless @$group_ids;
      return $app->db->select ('group', {
        context_key => $app->bare_param ('context_key'),
        group_id => {-in => $group_ids},
        (status_filter $app, '', 'owner_status', 'admin_status'),
      }, source_name => 'master', fields => ['group_id', 'created', 'updated', 'admin_status', 'owner_status'])->then (sub {
        return $_[0]->all->to_a;
      });
    })->then (sub {
      return $class->load_data ($app, '', 'group_data', 'group_id', undef, undef, $_[0], 'data');
    })->then (sub {
      return $class->load_icons ($app, 2, 'group_id', $_[0]);
    })->then (sub {
      return $app->send_json ({
        groups => {map {
          $_->{group_id} .= '';
          $_->{group_id} => $_;
        } @{$_[0]}},
      });
    });
  } # /group/profiles


  if (@$path >= 3 and $path->[1] eq 'member') {
    my $context = $app->bare_param ('context_key');
    my $group_id = $app->bare_param ('group_id');
    my $account_id = $app->bare_param ('account_id');
    return Promise->all ([
      $app->db->select ('group', {
        context_key => $context,
        group_id => $group_id,
      }, fields => ['group_id'], source_name => 'master'),
      $app->db->select ('account', {
        account_id => $account_id,
      }, fields => ['account_id'], source_name => 'master'),
    ])->then (sub {
      return $app->throw_error (404, reason_phrase => 'Bad |group_id|')
          unless $_[0]->[0]->first;
      return $app->throw_error (404, reason_phrase => 'Bad |account_id|')
          unless $_[0]->[1]->first;

      if (@$path == 3 and $path->[2] eq 'status') {
        ## /group/member/status - Set status fields of a group member
        ##
        ## With
        ##   context_key   An opaque string identifying the application.
        ##                 Required.
        ##   group_id      A group ID.  Required.
        ##   account_id    An account ID.  Required.
        ##   member_type   New member type.  A 7-bit non-negative integer.
        ##                 Default is "unchanged".
        ##   owner_status  New owner status.  A 7-bit non-negative integer.
        ##                 Default is "unchanged".
        ##   user_status   New user status.  A 7-bit non-negative integer.
        ##                 Default is "unchanged".
        ##
        ## If there is no group member record, a new record is
        ## created.  When a new record is created, the fields are set
        ## to |0| unless otherwise specified.
        $app->requires_request_method ({POST => 1});
        $app->requires_api_key;

        my $mt = $app->bare_param ('member_type');
        my $os = $app->bare_param ('owner_status');
        my $us = $app->bare_param ('user_status');
        my $time = time;
        return $app->db->insert ('group_member', [{
          context_key => $context,
          group_id => $group_id,
          account_id => $account_id,
          created => $time,
          updated => $time,
          member_type => $mt // 0,
          owner_status => $os // 0,
          user_status => $us // 0,
        }], duplicate => {
          updated => $app->db->bare_sql_fragment ('values(`updated`)'),
          (defined $mt ? (member_type => $app->db->bare_sql_fragment ('values(`member_type`)')) : ()),
          (defined $os ? (owner_status => $app->db->bare_sql_fragment ('values(`owner_status`)')) : ()),
          (defined $us ? (user_status => $app->db->bare_sql_fragment ('values(`user_status`)')) : ()),
        })->then (sub {
          return $app->send_json ({});
        });
      } # /group/member/status

      if (@$path == 3 and $path->[2] eq 'data') {
        ## /group/member/data - Write group member data
        ##
        ## With
        ##   context_key   An opaque string identifying the application.
        ##                 Required.
        ##   group_id      A group ID.  Required.
        ##   account_id    An account ID.  Required.
        ##   name (0+)   The keys of data pairs.  A key is an ASCII string.
        ##   value (0+)  The values of data pairs.  There must be same number
        ##               of |value|s as |name|s.  A value is a Unicode string.
        ##               An empty string is equivalent to missing.
        $app->requires_request_method ({POST => 1});
        $app->requires_api_key;

        my $time = time;
        my $names = $app->text_param_list ('name');
        my $values = $app->text_param_list ('value');
        my @data;
        for (0..$#$names) {
          push @data, {
            group_id => $group_id,
            account_id => $account_id,
            key => Dongry::Type->serialize ('text', $names->[$_]),
            value => Dongry::Type->serialize ('text', $values->[$_]),
            created => $time,
            updated => $time,
          } if defined $values->[$_];
        }
        return Promise->resolve->then (sub {
          return unless @data;
          return $app->db->insert ('group_member_data', \@data, duplicate => {
            value => $app->db->bare_sql_fragment ('VALUES(`value`)'),
            updated => $app->db->bare_sql_fragment ('VALUES(`updated`)'),
          });
        })->then (sub {
          return $app->send_json ({});
        });
      } # /group/member/data
    });
  } # /group/member

  if (@$path == 2 and $path->[1] eq 'members') {
    ## /group/members - List of group members
    ##
    ## With
    ##   context_key   An opaque string identifying the application.  Required.
    ##   group_id      A group ID.  Required.
    ##   account_id    An account ID.  Zero or more parameters can be
    ##                 specified.  If specified, only the members with
    ##                 ones of the specified account IDs are returned.
    ##   with_data
    ##
    ## Returns
    ##   memberships   Object of (account_id, group member object)
    ##
    ## Supports paging.
    ##
    ## Also, status filters |user_status| and |owner_status| with
    ## empty prefix are available.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 100, max_limit => 100);
    my $group_id = $app->bare_param ('group_id');
    my $aids = $app->bare_param_list ('account_id')->to_a;
    $_ = unpack 'Q', pack 'Q', $_ for @$aids;
    return $app->db->select ('group_member', {
      context_key => $app->bare_param ('context_key'),
      group_id => $group_id,
      (@$aids ? (account_id => {-in => $aids}) : ()),
      (defined $page->{value} ? (created => $page->{value}) : ()),
      (status_filter $app, '', 'user_status', 'owner_status'),
    }, fields => ['account_id', 'created', 'updated',
                  'user_status', 'owner_status', 'member_type'],
      source_name => 'master',
      offset => $page->{offset}, limit => $page->{limit},
      order => ['created', $page->{order_direction}],
    )->then (sub {
      my $members = $_[0]->all;
      return $class->load_data ($app, '', 'group_member_data', 'account_id', 'group_id' => $group_id, $members, 'data');
    })->then (sub {
      my $members = {map {
        $_->{account_id} .= '';
        ($_->{account_id} => $_);
      } @{$_[0]}};
      my $next_page = next_page $page, $members, 'created';
      return $app->send_json ({memberships => $members, %$next_page});
    });
  } # /group/members

  if (@$path == 2 and $path->[1] eq 'byaccount') {
    ## /group/byaccount - List of groups by account
    ##
    ## With
    ##   context_key   An opaque string identifying the application.  Required.
    ##   account_id    An account ID.  Required.
    ##   with_data
    ##   with_group_data
    ##   with_group_updated : Boolean   Whether the |group_updated|
    ##                                  should be returned or not.
    ##
    ## Returns
    ##   memberships   Object of (group_id, group member object)
    ##
    ##     If |with_group_updated| is true, each group member object
    ##     has |group_updated| field whose value is the group's
    ##     updated.
    ##
    ## Supports paging.
    ##
    ## Also, status filters |user_status| and |owner_status| with
    ## empty prefix are available.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 100, max_limit => 100);
    my $account_id = $app->bare_param ('account_id');
    my $context = $app->bare_param ('context_key');
    return $app->db->select ('group_member', {
      context_key => $context,
      account_id => $account_id,
      (defined $page->{value} ? (updated => $page->{value}) : ()),
      (status_filter $app, '', 'user_status', 'owner_status'),
    }, fields => ['group_id', 'created', 'updated',
                  'user_status', 'owner_status', 'member_type'],
      source_name => 'master',
      offset => $page->{offset}, limit => $page->{limit},
      order => ['updated', $page->{order_direction}],
    )->then (sub {
      my $groups = $_[0]->all;
      return $class->load_data ($app, '', 'group_member_data', 'group_id', 'account_id' => $account_id, $groups, 'data');
    })->then (sub {
      return $class->load_data ($app, 'group_', 'group_data', 'group_id', undef, undef, $_[0], 'group_data');
    })->then (sub {
      my $groups = $_[0];
      return $groups unless $app->bare_param ('with_group_updated');
      return $groups unless @$groups;
      return $app->db->select ('group', {
        context_key => $context,
        group_id => {-in => [map { $_->{group_id} } @$groups]},
        # status filters not applied here (for now, at least)
      }, fields => ['group_id', 'updated'], source_name => 'master')->then (sub {
        my $g2u = {};
        for (@{$_[0]->all}) {
          $g2u->{$_->{group_id}} = $_->{updated};
        }
        for (@$groups) {
          $_->{group_updated} = $g2u->{$_->{group_id}};
        }
        return $groups;
      });
    })->then (sub {
      my $groups = {map {
        $_->{group_id} .= '';
        ($_->{group_id} => $_);
      } @{$_[0]}};
      my $next_page = next_page $page, $groups, 'updated';
      return $app->send_json ({memberships => $groups, %$next_page});
    });
  } # /group/byaccount

  if (@$path == 2 and $path->[1] eq 'list') {
    ## /group/list - List of groups
    ##
    ## With
    ##   context_key   An opaque string identifying the application.  Required.
    ##   with_data
    ##
    ## Returns
    ##   groups        Object of (group_id, group object)
    ##
    ## Supports paging
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 100, max_limit => 100);
    my $account_id = $app->bare_param ('account_id');
    return $app->db->select ('group', {
      context_key => $app->bare_param ('context_key'),
      (defined $page->{value} ? (updated => $page->{value}) : ()),
      (status_filter $app, '', 'owner_status', 'admin_status'),
    }, source_name => 'master',
      fields => ['group_id', 'created', 'updated', 'admin_status', 'owner_status'],
      offset => $page->{offset}, limit => $page->{limit},
      order => ['updated', $page->{order_direction}],
    )->then (sub {
      return $_[0]->all->to_a;
    })->then (sub {
      return $class->load_data ($app, '', 'group_data', 'group_id', undef, undef, $_[0], 'data');
    })->then (sub {
      my $groups = {map {
        $_->{group_id} .= '';
        ($_->{group_id} => $_);
      } @{$_[0]}};
      my $next_page = next_page $page, $groups, 'updated';
      return $app->send_json ({
        groups => $groups,
        %$next_page,
      });
    });
  } # /group/list

  return $app->throw_error (404);
} # group

sub invite ($$$) {
  my ($class, $app, $path) = @_;

  if (@$path == 2 and $path->[1] eq 'create') {
    ## /invite/create - Create an invitation
    ##
    ## Parameters
    ##   context_key   An opaque string identifying the application.  Required.
    ##   invitation_context_key An opaque string identifying the kind
    ##                 or target of the invitation.  Required.
    ##   account_id    The ID of the account who creates the invitation.
    ##                 Required.  This must be a valid account ID (not
    ##                 verified by the end point).
    ##   data          A JSON data packed within the invitation.  Default
    ##                 is |null|.
    ##   expires       The expiration date of the invitation, in Unix time
    ##                 number.  Default is now + 24 hours.
    ##   target_account_id The ID of the account who can use the invitation.
    ##                 Default is |0|, which indicates the invitation can
    ##                 be used by anyone.  Otherwise, this must be a valid
    ##                 account ID (not verified by the end point).
    ##
    ## Returns
    ##   context_key   Same as parameter, echoed just for convenience.
    ##   invitation_context_key Same as parameter, echoed just for convenience.
    ##   invitation_key An opaque string identifying the invitation.
    ##
    ##   expires : Timestamp     The invitation's expiration time.
    ##
    ##   timestamp : Timestamp   The invitation's created time.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $context_key = $app->bare_param ('context_key')
        // return $app->throw_error (400, reason_phrase => 'No |context_key|');
    my $inv_context_key = $app->bare_param ('invitation_context_key')
        // return $app->throw_error (400, reason_phrase => 'No |invitation_context_key|');
    my $author_account_id = $app->bare_param ('account_id')
        or return $app->throw_error (400, reason_phrase => 'No |account_id|');
    my $data = Dongry::Type->parse ('json', $app->bare_param ('data'));
    my $invitation_key = id 30;
    my $time = time;
    my $expires = $app->bare_param ('expires');
    $expires = $time + 24*60*60 unless defined $expires;
    return $app->db->insert ('invitation', [{
      context_key => $context_key,
      invitation_context_key => $inv_context_key,
      invitation_key => $invitation_key,
      author_account_id => $author_account_id,
      invitation_data => Dongry::Type->serialize ('json', $data) // 'null',
      target_account_id => $app->bare_param ('target_account_id') || 0,
      created => $time,
      expires => $expires,
      user_account_id => 0,
      used_data => 'null',
      used => 0,
    }])->then (sub {
      return $app->send_json ({
        context_key => $context_key,
        invitation_context_key => $inv_context_key,
        invitation_key => $invitation_key,
        timestamp => $time,
        expires => $expires,
      });
    });
  } # /invite/create

  if (@$path == 2 and $path->[1] eq 'use') {
    ## /invite/use - Use an invitation
    ##
    ## Parameters
    ##   context_key   An opaque string identifying the application.  Required.
    ##   invitation_context_key An opaque string identifying the kind
    ##                 or target of the invitation.  Required.
    ##   invitation_key An opaque string identifying the invitation.  Required.
    ##   account_id    The ID of the account who uses the invitation.
    ##                 Required unless |ignore_target| is true.  If missing,
    ##                 defaulted to zero.
    ##                 This must be a valid account ID (not verified by the
    ##                 end point).
    ##   ignore_target If true, target account of the invitation is ignored.
    ##                 This parameter can be used to disable the invitation
    ##                 (e.g. by the owner of the target resource).
    ##   data          A JSON data saved with the invitation.  Default
    ##                 is |null|.
    ##
    ## Returns
    ##   invitation_data The JSON data saved when the invitation was created.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $context_key = $app->bare_param ('context_key')
        // return $app->throw_error (400, reason_phrase => 'Bad |context_key|');
    my $inv_context_key = $app->bare_param ('invitation_context_key')
        // return $app->throw_error (400, reason_phrase => 'Bad |invitation_context_key|');
    my $invitation_key = $app->bare_param ('invitation_key')
        // return $app->throw_error_json ({reason => 'Bad |invitation_key|'});
    my $ignore_target = $app->bare_param ('ignore_target');
    my $user_account_id = $app->bare_param ('account_id')
        or $ignore_target
        or return $app->throw_error (400, reason_phrase => 'No |account_id|');
    $user_account_id = unpack 'Q', pack 'Q', $user_account_id if defined $user_account_id;
    my $data = Dongry::Type->parse ('json', $app->bare_param ('data'));
    my $time = time;
    return $app->db->update ('invitation', {
      user_account_id => $user_account_id // 0,
      used_data => Dongry::Type->serialize ('json', $data) // 'null',
      used => $time,
    }, where => {
      context_key => $context_key,
      invitation_context_key => $inv_context_key,
      invitation_key => $invitation_key,
      ($ignore_target ? () : (target_account_id => {-in => [0, $user_account_id]})),
      expires => {'>=', $time},
      used => 0,
    })->then (sub {
      unless ($_[0]->row_count == 1) {
        ## Either:
        ##   - Invitation key is invalid
        ##   - context_key or invitation_context_key is wrong
        ##   - The account is not the target of the invitation
        ##   - The invitation has expired
        ##   - The invitation has been used
        return $app->throw_error_json ({reason => 'Bad invitation'});
      }
      return $app->db->select ('invitation', {
        context_key => $context_key,
        invitation_context_key => $inv_context_key,
        invitation_key => $invitation_key,
      }, fields => ['invitation_data'], source_name => 'master');
    })->then (sub {
      my $d = $_[0]->first // die "Invitation not found";
      return $app->send_json ({
        invitation_data => Dongry::Type->parse ('json', $d->{invitation_data}),
      });
    });
  } # /invite/use

  if (@$path == 2 and $path->[1] eq 'open') {
    ## /invite/open - Get an invitation for recipient
    ##
    ## Parameters
    ##   context_key   An opaque string identifying the application.  Required.
    ##   invitation_context_key An opaque string identifying the kind
    ##                 or target of the invitation.  Required.
    ##   invitation_key An opaque string identifying the invitation.  Required.
    ##   account_id    The ID of the account who reads the invitation.
    ##                 Can be |0| for "anyone".  Required.  This must be
    ##                 a valid account ID (not verified by the end point).
    ##   with_used_data : Boolean If true, |used_data| is returned, if any.
    ##
    ## Returns
    ##   author_account_id
    ##   invitation_data The JSON data saved when the invitation was created.
    ##   target_account_id
    ##   created
    ##   expires
    ##   used
    ##   used_data : Object?
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $context_key = $app->bare_param ('context_key');
    my $inv_context_key = $app->bare_param ('invitation_context_key');
    my $invitation_key = $app->bare_param ('invitation_key');
    my $user_account_id = unpack 'Q', pack 'Q', ($app->bare_param ('account_id') || 0);
    my $wud = $app->bare_param ('with_used_data');
    return $app->db->select ('invitation', {
      context_key => $context_key,
      invitation_context_key => $inv_context_key,
      invitation_key => $invitation_key,
      target_account_id => {-in => [0, $user_account_id]},
    }, fields => [
      'author_account_id', 'invitation_data',
      'target_account_id', 'created', 'expires',
      'used', ($wud ? 'used_data' : ()),
    ], source_name => 'master')->then (sub {
      my $d = $_[0]->first
          // return $app->throw_error_json ({reason => 'Bad invitation'});
      $d->{invitation_key} = $invitation_key;
      $d->{invitation_data} = Dongry::Type->parse ('json', $d->{invitation_data});
      $d->{used_data} = Dongry::Type->parse ('json', $d->{used_data})
          if defined $d->{used_data};
      return $app->send_json ($d);
    });
  } # /invite/open

  if (@$path == 2 and $path->[1] eq 'list') {
    ## /invite/list - Get invitations for owners
    ##
    ## Parameters
    ##   context_key             An opaque string identifying the application.
    ##                           Required.
    ##   invitation_context_key  An opaque string identifying the kind
    ##                           or target of the invitation.  Required.
    ##   unused : Boolean        If specified, only invitations whose used is
    ##                           false is returned.
    ##
    ## Returns
    ##   invitations   Object of (invitation_key, inivitation object)
    ##
    ## Supports paging.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 50, max_limit => 100);
    my $context_key = $app->bare_param ('context_key');
    my $inv_context_key = $app->bare_param ('invitation_context_key');
    return $app->db->select ('invitation', {
      context_key => $context_key,
      invitation_context_key => $inv_context_key,
      (defined $page->{value} ? (created => $page->{value}) : ()),
      ($app->bare_param ('unused') ? (used => 0) : ()),
    }, fields => ['invitation_key', 'author_account_id', 'invitation_data',
                   'target_account_id', 'created', 'expires',
                   'used', 'used_data', 'user_account_id'],
      source_name => 'master',
      offset => $page->{offset}, limit => $page->{limit},
      order => ['created', $page->{order_direction}],
    )->then (sub {
      my $items = $_[0]->all->to_a;
      for (@$items) {
        $_->{invitation_data} = Dongry::Type->parse ('json', $_->{invitation_data});
        $_->{used_data} = Dongry::Type->parse ('json', $_->{used_data});
        $_->{author_account_id} .= '';
        $_->{target_account_id} .= '';
        $_->{user_account_id} .= '';
      }
      my $next_page = next_page $page, $items, 'created';
      return $app->send_json ({invitations => {map { $_->{invitation_key} => $_ } @$items}, %$next_page});
    });
  } # /invite/list

  return $app->throw_error (404);
} # invite

sub icon ($$$) {
  my ($class, $app, $path) = @_;

  if (@$path == 2 and $path->[1] eq 'updateform') {
    ## /icon/updateform - Get form data to update the icon
    ##
    ## Parameters
    ##   context_key   An opaque string identifying the application.
    ##                 Required.  Note that this is irrelevant to
    ##                 group's |context_key|.
    ##   target_type   Type of the target with which the icon is associated.
    ##                   1 - account
    ##                   2 - group
    ##   target_id     The identifier of the target with which the icon is
    ##                 associated, depending on |target_type|.  It must
    ##                 be a valid target identifier.  It's application's
    ##                 responsibility to ensure the value is valid.
    ##   mime_type     The MIME type of the icon to be submitted.  Either
    ##                 |image/jpeg| or |image/png|.
    ##   byte_length   The byte length of the icon to be submitted.
    ##
    ## Returns
    ##   form_data     Object of |name|/|value| pairs of |hidden| form data.
    ##   form_url      The |action| URL of the form.
    ##   form_expires  The expiration time of the form, in Unix time.
    ##   icon_url      The result URL of the submitted icon.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $context_key = $app->bare_param ('context_key')
        // return $app->throw_error (400, reason_phrase => 'Bad |context_key|');
    my $target_type = $app->bare_param ('target_type') || 0;
    return $app->throw_error (400, reason_phrase => 'Bad |target_type|')
        unless $target_type eq '1' or $target_type eq '2';
    my $target_id = $app->bare_param ('target_id')
        // return $app->throw_error (400, reason_phrase => 'Bad |target_id|');
    
    my $mime_type = $app->bare_param ('mime_type') // '';
    return $app->throw_error_json ({reason => 'Bad |mime_type|'})
        unless $mime_type eq 'image/jpeg' or $mime_type eq 'image/png';
    
    my $byte_length = 0+($app->bare_param ('byte_length') || 0);
    return $app->throw_error_json ({reason => 'Bad |byte_length|'})
        unless 0 < $byte_length and $byte_length <= 10*1024*1024;

    my $cfg = sub {
      my $n = $_[0];
      return $app->config->get ($n . '.' . $context_key) //
             $app->config->get ($n); # or undef
    }; # $cfg

    my $time = time;
    return $app->db->select ('icon', {
      context_key => Dongry::Type->serialize ('text', $context_key),
      target_type => $target_type,
      target_id => $target_id,
    }, source_name => 'master', fields => ['url'])->then (sub {
      my $v = $_[0]->first;
      if (defined $v) {
        return $app->db->update ('icon', {
          updated => $time,
        }, where => {
          context_key => $context_key,
          target_type => $target_type,
          target_id => $target_id,
        })->then (sub { return $v->{url} });
      }

      return $app->db->execute ('select uuid_short() as `id`', undef, source_name => 'master')->then (sub {
        my $id = $_[0]->first->{id};
    
        my $key_prefix = $cfg->('s3_key_prefix') // '';
        my $key = "$id";
        $key = "$key_prefix/$key" if length $key_prefix;

        ## Not changed when updated.
        $key .= {
          'image/png' => '.png',
          'image/jpeg' => '.jpeg',
        }->{$mime_type} // '';
        
        return $app->db->insert ('icon', [{
          context_key => $context_key,
          target_type => $target_type,
          target_id => $target_id,
          created => $time,
          updated => $time,
          admin_status => 1, # open
          url => Dongry::Type->serialize ('text', $key),
        }])->then (sub { return $key }); # duplicate is error!
      });
    })->then (sub {
      my $key = $_[0];
      
      #my $image_url = "https://$service-$region.amazonaws.com/$bucket/$key";
      #my $image_url = "https://$bucket/$key";
      my $image_url = $cfg->('s3_image_url_prefix') . $key . '?' . $time;
      my $bucket = $cfg->('s3_bucket');

      my $accesskey = $cfg->('s3_access_key_id');
      my $secret = $cfg->('s3_secret_access_key');
      my $region = $cfg->('s3_region');
      my $token;
      my $expires;
      my $max_age = 60*60;
      
      return Promise->resolve->then (sub {
        my $sts_role_arn = $cfg->('s3_sts_role_arn');
        return unless defined $sts_role_arn;
        my $sts_url = Web::URL->parse_string
            (qq<https://sts.$region.amazonaws.com/>);
        my $sts_client = Web::Transport::ConnectionClient->new_from_url
            ($sts_url);
        $expires = time + $max_age;
        return $sts_client->request (
          url => $sts_url,
          params => {
            Version => '2011-06-15',
            Action => 'AssumeRole',
            ## Maximum length = 64 (sha1_hex length = 40)
            RoleSessionName => 'accounts-icon-' . sha1_hex ($context_key),
            RoleArn => $sts_role_arn,
            Policy => perl2json_chars ({
              "Version" => "2012-10-17",
              "Statement" => [
                {'Sid' => "Stmt1",
                 "Effect" => "Allow",
                 "Action" => ["s3:PutObject", "s3:PutObjectAcl"],
                 "Resource" => "arn:aws:s3:::$bucket/*"},
              ],
            }),
            DurationSeconds => $max_age,
          },
          aws4 => [$accesskey, $secret, $region, 'sts'],
        )->then (sub {
          my $res = $_[0];
          die $res unless $res->status == 200;

          my $doc = new Web::DOM::Document;
          my $parser = new Web::XML::Parser;
          $parser->onerror (sub { });
          $parser->parse_byte_string ('utf-8', $res->body_bytes => $doc);
          $accesskey = $doc->get_elements_by_tag_name
              ('AccessKeyId')->[0]->text_content;
          $secret = $doc->get_elements_by_tag_name
              ('SecretAccessKey')->[0]->text_content;
          $token = $doc->get_elements_by_tag_name
              ('SessionToken')->[0]->text_content;
        });
      })->then (sub {
        my $acl = "public-read";
        #my $redirect_url = ...;
        my $form_data = Web::Transport::AWS->aws4_post_policy
            (clock => Web::DateTime::Clock->realtime_clock,
             max_age => $max_age,
             access_key_id => $accesskey,
             secret_access_key => $secret,
             security_token => $token,
             region => $region,
             service => 's3',
             policy_conditions => [
               {"bucket" => $bucket},
               {"key", $key}, #["starts-with", q{$key}, $prefix],
               {"acl" => $acl},
               #{"success_action_redirect" => $redirect_url},
               {"Content-Type" => $mime_type},
               ["content-length-range", $byte_length, $byte_length],
             ]);
        return $app->send_json ({
          form_data => {
            key => $key,
            acl => $acl,
            #success_action_redirect => $redirect_url,
            "Content-Type" => $mime_type,
            %$form_data,
          },
          form_url => $cfg->('s3_form_url'),
          icon_url => $image_url,
        });
      });
    });
  } # /icon/updateform
  
  return $app->throw_error (404);
} # icon

1;

=head1 LICENSE

Copyright 2007-2023 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You does not have received a copy of the GNU Affero General Public
License along with this program, see <https://www.gnu.org/licenses/>.

=cut
