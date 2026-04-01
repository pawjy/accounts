package Accounts::Web::Login;
use strict;
use warnings;
use Time::HiRes qw(time);
use File::Temp;
use JSON::PS;
use Digest::SHA qw(sha1_hex);
use Crypt::OpenSSL::Random;
use Crypt::PK::Ed25519;
use Web::Encoding;
use Web::URL::Encoding;
use Web::Transport::Base64;
push our @ISA, qw(Accounts::Web);

BEGIN { *status_filter = \&Accounts::Web::status_filter }
BEGIN { *id = \&Accounts::Web::id }
BEGIN { *format_id = \&Accounts::Web::format_id }
BEGIN { *this_page = \&Accounts::Web::this_page }
BEGIN { *next_page = \&Accounts::Web::next_page }

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

sub login ($$$) {
  my ($class, $app, $path) = @_;

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
          // return $app->throw_error_json ({reason => 'Bad session',
                                            error_for_dev => "/create bad session"});
      my $session_data = $session_row->get ('data');
      if (defined $session_data->{account_id}) {
        return $app->throw_error_json ({reason => 'Account-associated session'});
      }

      my $time = time;
      return $app->db->uuid_short (2, source_name => 'master')->then (sub {
        my $ids = $_[0];
        my $account_id = format_id $ids->[0];
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
            account_log_id => format_id $ids->[1],
          });
        });
      })->then (sub {
        return $class->write_session_log ($app, $session_row, $time, force => 1);
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
    ##   |select_account_on_multiple| : Boolean - If true and when there
    ##                    are multiple possible accounts, a list of them
    ##                    is returned.  If false, one of them are chosen.
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
        select_account_on_multiple => ($path->[0] eq 'login' and $app->bare_param ('select_account_on_multiple')),
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
    ##   |sk|, |state|, |reloaded|, |code|
    ##   Operation source parameters.
    ##
    ## Returns
    ##
    ##   |needs_account_selection| : Boolean   - True when there are
    ##                            multiple candidate accounts.
    ##   |accounts| : Array?    - The candidate accounts.
    ##     |account_id| : ID    - The account ID.
    ##     |name| : Text        - The account's name.
    ##   |app_data| : Object?   - Application-specific data given when
    ##                            the flow has started, if any and login
    ##                            successed.
    ##
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
            my $time = time;
            return $class->login_account ($app, $server, $session_data, $time)->then (sub {
              my $login_result = $_[0];
              if (defined $login_result->{multiple_accounts_found}) {
                return $session_row->update ({data => $session_data}, source_name => 'master')->then (sub {
                  return $login_result; # need to be continued
                });
              }
              return $class->write_session_log ($app, $session_row, $time, force => 1)->then (sub {
                return {}; # Success
              });
            });
          } elsif ($session_data->{action}->{operation} eq 'link') {
            return $class->link_account ($app, $server, $session_data)->then(sub {
              return {}; # Success
            });
          } else {
            die "Bad operation |$session_data->{action}->{operation}|";
          }
        })->then (sub {
          my $result = $_[0];
          if (defined $result->{multiple_accounts_found}) {
            ## Account selection is needed.
            my $app_data = $session_data->{action}->{app_data};
            return $app->send_json ({
              needs_account_selection => 1,
              accounts => $result->{accounts},
            });
          } else {
            return $class->finalize_login_session ($app, $session_row)->then (sub {
              return $app->send_json ($_[0]);
            });
          }
        });
      }, sub {
        warn $_[0];
        return $app->send_error_json ({reason => 'OAuth token endpoint failed',
                                       error_for_dev => "$_[0]"});
      })->then (sub {
        return $class->delete_old_sessions ($app);
      });
    });
  } elsif (@$path == 2 and $path->[0] eq 'login' and $path->[1] eq 'continue') {
    ## /login/continue - Continue login flow after account selection
    ##
    ## Parameters
    ##
    ##   |sk_context|, |sk|
    ##   |selected_account_id| : ID : The account ID selected by the user.
    ##   Operation source parameters.
    ##
    ## Returns
    ##
    ##   |app_data| : Object?   - Application-specific data given when
    ##                            the flow has started, if any and login
    ##                            successed.
    ##
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $selected_account_id = $app->bare_param ('selected_account_id')
        // return $app->send_error_json
                      ({reason => 'No |selected_account_id|'});

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0]
          // return $app->send_error_json
                        ({reason => 'Bad session',
                          error_for_dev => '/login/continue bad session'});

      my $session_data = $session_row->get('data');
      my $endpoint = $session_data->{action}->{endpoint} // '';
      return $app->send_error_json ({reason => 'Bad login flow state'})
          unless $endpoint eq 'oauth' or $endpoint eq 'email';

      my $time = time;
      return ($endpoint eq 'email' ?
        $class->login_account_by_email (
          $app, $session_data, $time,
          selected_account_id => $selected_account_id,
        ) : do {
        my $server = $app->config->get_oauth_server ($session_data->{action}->{server})
            or $app->send_error(500);
        $class->login_account ($app, $server, $session_data, $time,
                               selected_account_id => $selected_account_id);
      })->then (sub {
        my $login_result = $_[0];
        if (defined $login_result->{multiple_accounts_found}) {
          return $app->throw_error_json
              ({reason => 'Internal error during login continuation'});
        } else {
          return $class->write_session_log
              ($app, $session_row, $time, force => 1);
        }
      })->then(sub {
        my $account_id = $session_data->{account_id};
        return $class->finalize_login_session ($app, $session_row)->then (sub {
          my $json = $_[0];
          $json->{account_id} = ''.$account_id;
          return $json;
        });
      })->then (sub {
        return $app->send_json ($_[0]);
      });
    });
  } # /login/continue

  if (@$path == 3 and $path->[0] eq 'login' and $path->[1] eq 'email' and $path->[2] eq 'request') {
    ## /login/email/request - Request a secret number for email login
    ##
    ## Parameters
    ##   |addr| : Text : Email address.
    ##   Operation source parameters.
    ##
    ## Returns
    ##   |secret_number| : String? :     The generated secret number, if
    ##                                   applicable.
    ##   |secret_expires| : Timestamp? : The expiration of the |secret_number|,
    ##                                   if applicable.
    ##   |should_send_email| : Boolean : Whether an email should be sent.
    ##
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $addr = $app->text_param ('addr') // '';
    unless ($addr =~ /\A[\x21-\x3F\x41-\x7E]+\@[\x21-\x3F\x41-\x7E]+\z/) {
      return $app->send_error_json ({reason => 'Bad email address'});
    }
    my $email_sha = sha1_hex encode_web_utf8 $addr;
    my $ipaddr = $app->bare_param ('source_ipaddr') // '';
    my $time = time;

    my $result_json = {should_send_email => 0};
    my $log_data = {linked_email => $addr};

    my $ip_limit = $app->config->get ('login_email_rate_limit_ip_count') || 100;
    my $ip_window = $app->config->get ('login_email_rate_limit_ip_window') || 600;
    my $email_limit = $app->config->get ('login_email_rate_limit_email_count') || 5;
    my $email_window = $app->config->get ('login_email_rate_limit_email_window') || 3600;

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0]
          // return $app->throw_error_json ({reason => 'Bad session'});

      ## IP-based rate limit (Count all requests from account_log)
      return $app->db->select ('account_log', {
        action => 'login/email/request',
        ipaddr => $ipaddr,
        timestamp => {'>', $time - $ip_window},
      }, fields => [{-count => undef, as => 'c'}], source_name => 'master')->then (sub {
        if (($_[0]->first || {})->{c} >= $ip_limit) {
          $log_data->{result} = 'rate_limited';
          $log_data->{reason} = 'IP rate limit';
          return 0;
        }
        return 1;
      });
    })->then (sub {
      return 0 unless $_[0];
      ## Email-based rate limit
      return $app->db->select ('login_token', {
        email_sha => Dongry::Type->serialize ('text', $email_sha),
        created => {'>', $time - $email_window},
      }, fields => [{-count => undef, as => 'c'}], source_name => 'master')->then (sub {
        if (($_[0]->first || {})->{c} >= $email_limit) {
          $log_data->{result} = 'rate_limited';
          $log_data->{reason} = 'Email rate limit';
          return 0;
        }
        return 1;
      });
    })->then (sub {
      return 0 unless $_[0];
      ## Check if email is registered
      return $app->db->select ('account_link', {
        service_name => 'email',
        linked_email => Dongry::Type->serialize ('text', $addr),
      }, fields => ['account_id'], source_name => 'master', limit => 1)->then (sub {
        my $row = $_[0]->first;
        if (defined $row) {
          my $account_id = $row->{account_id};
          ## Check account status
          return $app->db->select ('account', {
            account_id => $account_id,
            user_status => 1,
            admin_status => 1,
          }, fields => ['account_id'], source_name => 'master', limit => 1)->then (sub {
            my $acc = $_[0]->first;
            if (defined $acc) {
              return {account_id => $acc->{account_id}};
            } else {
              $log_data->{result} = 'not_found';
              return undef;
            }
          });
        } else {
          $log_data->{result} = 'not_found';
          return undef;
        }
      });
    })->then (sub {
      my $found = $_[0];
      if ($found) {
        my $account_id = $found->{account_id};
        my $secret = $class->generate_8digit_secret;
        return $app->db->transaction->then (sub {
          my $tr = $_[0];
          ## Revoke existing tokens for this email
          return $tr->update ('login_token', {
            status => 2, # revoked
          }, where => {
            email_sha => $email_sha,
            status => 1,
          }, source_name => 'master')->then (sub {
            return $tr->insert ('login_token', [{
              email_sha => $email_sha,
              token => $secret,
              expires => $result_json->{secret_expires} = $time + 600,
              created => $time,
              ipaddr => Dongry::Type->serialize ('text', $ipaddr),
              attempts => 0,
              status => 1, # active
            }], source_name => 'master');
          })->then (sub {
            return $tr->commit;
          })->then (sub {
            $result_json->{secret_number} = $secret;
            $result_json->{should_send_email} = 1;
            $log_data->{result} = 'sent';
            return $account_id;
          });
        });
      } else {
        return 0; # Not found or rate limited
      }
    })->then (sub {
      my $account_id = $_[0] || 0;
      return $app->db->uuid_short (1)->then (sub {
        return $app->db->insert ('account_log', [{
          log_id => $_[0]->[0],
          account_id => $account_id, # one of them
          operator_account_id => 0,
          timestamp => $time,
          action => 'login/email/request',
          ua => $app->bare_param ('source_ua') // '',
          ipaddr => $ipaddr,
          data => Dongry::Type->serialize ('json', $log_data),
        }]);
      });
    })->then (sub {
      $app->send_json ($result_json);
      return $class->delete_old_login_tokens ($app);
    });
  } # /login/email/request

  if (@$path == 3 and $path->[0] eq 'login' and $path->[1] eq 'email' and $path->[2] eq 'verify') {
    ## /login/email/verify - Verify secret number and login
    ##
    ## Parameters
    ##   |addr| : Text : Email address.
    ##   |secret_number| : Text : The secret number.
    ##   |sk_context| : Text : Session context.
    ##   |sk| : Text? : Session key.
    ##   Operation source parameters.
    ##
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $addr = $app->text_param ('addr') // '';
    my $secret = $app->text_param ('secret_number') // '';
    my $email_sha = sha1_hex encode_web_utf8 $addr;
    my $time = time;
    my $log_data = {linked_email => $addr};

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0]
          // return $app->throw_error_json ({reason => 'Bad session'});

      return $app->db->select ('login_token', {
        email_sha => $email_sha,
        status => 1, # active
      }, source_name => 'master', order => [created => 'DESC'], limit => 1)->then (sub {
        my $row = $_[0]->first;
        unless ($row) {
          $log_data->{result} = 'failed';
          $log_data->{reason} = 'No active token';
          return {status => 400, reason => 'Invalid secret number'};
        }

        if ($row->{expires} < $time) {
          $log_data->{result} = 'expired';
          return $app->db->update ('login_token', {
            status => 2, # revoked
          }, where => {
            email_sha => $email_sha,
          }, source_name => 'master')->then (sub {
            return {status => 400, reason => 'Expired secret number'};
          });
        }

        my $attempts_limit = $app->config->get ('login_email_attempts_limit_count') || 5;
        if ($row->{attempts} >= $attempts_limit) {
          $log_data->{result} = 'too_many_attempts';
          return $app->db->update ('login_token', {
            status => 2, # revoked
          }, where => {
            email_sha => $email_sha,
          }, source_name => 'master')->then (sub {
            return {status => 400, reason => 'Too many attempts'};
          });
        }

        if ($row->{token} eq $secret and length $secret) {
          ## Success
          return $app->db->update ('login_token', {
            status => 2, # revoked
          }, where => {
            email_sha => $email_sha,
          }, source_name => 'master')->then (sub {
            my $session_data = $session_row->get ('data');
            $session_data->{email} = {
              linked_id => $email_sha,
              linked_email => $addr,
            };
            $session_data->{action} = {
              endpoint => 'email',
              operation => 'login',
            };

            return $class->login_account_by_email ($app, $session_data, $time)->then (sub {
              my $login_result = $_[0];
              if (defined $login_result->{multiple_accounts_found}) {
                $log_data->{result} = 'success';
                $log_data->{multiple_accounts} = 1;
                return $session_row->update ({data => $session_data}, source_name => 'master')->then (sub {
                  return {status => 200, json => {
                    needs_account_selection => 1,
                    accounts => $login_result->{accounts},
                  }};
                });
              } else {
                return $class->finalize_login_session ($app, $session_row)->then (sub {
                  my $json = $_[0];
                  $json->{account_id} = $session_data->{account_id};
                  $log_data->{result} = 'success';
                  return {status => 200, json => $json, account_id => $json->{account_id}};
                });
              }
            });
          });
        } else {
          $log_data->{result} = 'failed';
          return $app->db->execute ('UPDATE login_token SET attempts = attempts + 1 WHERE email_sha = ? AND status = 1', {
            email_sha => $email_sha,
          }, source_name => 'master')->then (sub {
            return {status => 400, reason => 'Invalid secret number'};
          });
        }
      });
    })->then (sub {
      my $res = $_[0];
      my $account_id = $res->{account_id} || 0;
      return $app->db->uuid_short (1)->then (sub {
        return $app->db->insert ('account_log', [{
          log_id => $_[0]->[0],
          account_id => $account_id,
          operator_account_id => $account_id,
          timestamp => $time,
          action => 'login/email/verify',
          ua => $app->bare_param ('source_ua') // '',
          ipaddr => $app->bare_param ('source_ipaddr') // '',
          data => Dongry::Type->serialize ('json', $log_data),
        }]);
      })->then (sub {
        if ($res->{status} == 200) {
          return $app->send_json ($res->{json});
        } else {
          $app->http->set_status ($res->{status});
          return $app->send_json ({reason => $res->{reason}});
        }
      });
    })->then (sub {
      return $class->delete_old_login_tokens ($app);
    });
  } # /login/email/verify

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
            $log_id = format_id $v->{uuid2};
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
        my $link_id = format_id $_[0]->[1]->[0];
        my $log_id = format_id $_[0]->[1]->[1];
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
        my $link_id = format_id $_[0]->[0];
        my $log_id = format_id $_[0]->[1];
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
          if (not defined $link_id and not $all) or
             ($all and defined $link_id);
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
          my $log_id = format_id $_[0]->first->{1};
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
            $data->{account_link_id} = format_id $link_id;
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

  return $app->send_error (404);
} # login

sub generate_8digit_secret ($) {
  my $bytes = Crypt::OpenSSL::Random::random_bytes (4);
  my $num = unpack 'L', $bytes;
  return sprintf '%08d', $num % 100000000;
} # generate_8digit_secret

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

sub login_account_by_email ($$$$;%) {
  my ($class, $app, $session_data, $time, %args) = @_;
  my $email_data = $session_data->{email}
      // return $app->throw_error_json ({reason => 'Bad login flow state'});
  my $email_sha = $email_data->{linked_id};

  return $app->db->select ('account_link', {
    service_name => 'email',
    linked_id => Dongry::Type->serialize ('text', $email_sha),
  }, fields => ['account_id'], source_name => 'master')->then (sub {
    my $links = $_[0]->all;
    return {status => 400, reason => 'Invalid secret number'} unless @$links;
    my @account_ids = map { $_->{account_id} } @$links;

    return $app->db->select ('account', {
      account_id => {-in => \@account_ids},
      user_status => 1,
      admin_status => 1,
    }, fields => ['account_id', 'name'], source_name => 'master')->then (sub {
      my $accounts = $_[0]->all;
      unless (@$accounts) {
        return $app->throw_error_json ({status => 403, reason => 'Account disabled'});
      }

      if (@$accounts > 1 and not defined $args{selected_account_id}) {
        return {
          multiple_accounts_found => 1,
          accounts => [map {
            {account_id => format_id $_->{account_id}, name => $_->{name}};
          } @$accounts],
        };
      }

      my $account;
      if (defined $args{selected_account_id}) {
        $account = (grep { $_->{account_id} eq $args{selected_account_id} } @$accounts)[0];
        return $app->throw_error_json
            ({reason => 'Selected account did not match linked accounts'})
            unless defined $account;
      } else {
        $account = $accounts->[0];
      }

      $session_data->{account_id} = format_id $account->{account_id};
      return {};
    });
  });
} # login_account_by_email

sub login_account ($$$$;%) {
  my ($class, $app, $server, $session_data, $time, %args) = @_;
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

    if (@$links) {
      if (defined $args{selected_account_id}) {
        $links = [grep { $_->{account_id} eq $args{selected_account_id} } @$links];
        return $app->throw_error_json
            ({reason => 'Selected account did not match linked accounts'})
            unless @$links == 1;

        #
      } elsif ($session_data->{action}->{select_account_on_multiple}) {
        my @account_ids = map { $_->{account_id} } @$links;
        return $app->db->select ('account', {
          account_id => {-in => \@account_ids, user_status => 1, admin_status => 1},
        }, fields => ['account_id', 'name'], source_name => 'master')->then(sub {
          my $accounts = $_[0]->all_as_rows;
          return [{
            multiple_accounts_found => 1,
            accounts => [map {
              {account_id => ''.$_->get ('account_id'),
               name => $_->get ('name')};
            } @$accounts],
          }];
        });
      } else {
        #
      }
      $links = [$links->[0]];
    } # @$links

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
    } else {
      die "This should not be reached";
    }
  })->then (sub {
    return $_[0]->[0] if defined $_[0]->[0]->{multiple_accounts_found};

    my ($account, $account_link) = @{$_[0]};
    unless ($account->{user_status} == 1) {
      return $app->throw_error_json ({
        reason => 'Bad account |user_status|',
        account_id => ''.$account->{account_id},
        user_status => $account->{user_status},
        admin_status => $account->{admin_status},
      });
    }
    unless ($account->{admin_status} == 1) {
      return $app->throw_error_json ({
        reason => 'Bad account |admin_status|',
        account_id => ''.$account->{account_id},
        user_status => $account->{user_status},
        admin_status => $account->{admin_status},
      });
    }
    $session_data->{account_id} = format_id $account->{account_id};
    return {};
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

sub finalize_login_session ($$$) {
  my ($class, $app, $session_row) = @_;
  my $session_data = $session_row->get ('data');

  my $app_data = $session_data->{action}->{app_data}; # or undef
  my $json = {app_data => $app_data};
  if (($session_data->{action}->{operation} // '') eq 'login') {
    $session_data->{login_time} = time;

    my $lk = $app->bare_param ('lk') // '';
    my $origin = $app->bare_param ('origin') // '';
    my $lk_expires = time + 60*60*24*400;
    if (not verify_lk ($app->config, $lk, $origin, $lk_expires)) {
      $json->{lk} = create_lk ($app->config, $origin);
      if (defined $json->{lk}) {
        $json->{lk_expires} = $lk_expires;
        $json->{is_new} = 1;
      }
    }
  }

  delete $session_data->{action};
  return $session_row->update ({data => $session_data}, source_name => 'master')->then (sub {
    return $json;
  });
} # finalize_login_session

## An account link object:
##
##   ...
##   |account_link_id|   The ID of the account link object.
sub Accounts::Web::load_linked ($$$) {
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

1;

=head1 LICENSE

Copyright 2007-2026 Wakaba <wakaba@suikawiki.org>.

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
