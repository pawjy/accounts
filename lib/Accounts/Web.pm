package Accounts::Web;
use strict;
use warnings;
use Path::Tiny;
use File::Temp;
use Promise;
use Promised::File;
use Promised::Command;
use JSON::PS;
use Digest::SHA qw(sha1_hex);
use Wanage::URL;
use Wanage::HTTP;
use Dongry::Type;
use Dongry::Type::JSONPS;
use Dongry::SQL;
use Accounts::AppServer;
use Web::UserAgent::Functions qw(http_post http_get);
use Web::UserAgent::Functions::OAuth;

sub format_id ($) {
  return sprintf '%llu', $_[0];
} # format_id

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

    # XXX accesslog
    warn sprintf "Access: [%s] %s %s\n",
        scalar gmtime, $app->http->request_method, $app->http->url->stringify;

    return $app->execute_by_promise (sub {
      return Promise->resolve->then (sub {
        return $class->main ($app);
      })->then (sub {
        return $app->shutdown;
      }, sub {
        my $error = $_[0];
        return $app->shutdown->then (sub { die $error });
      })->catch (sub {
        $app->error_log ($_[0])
            unless UNIVERSAL::isa ($_[0], 'Warabe::App::Done');
        die $_[0];
      });
    });
  };
} # psgi_app

{
  my @alphabet = ('A'..'Z', 'a'..'z', 0..9);
  sub id ($) {
    my $key = '';
    $key .= $alphabet[rand @alphabet] for 1..$_[0];
    return $key;
  } # id
}

my $SessionTimeout = 60*60*24*10;

sub main ($$) {
  my ($class, $app) = @_;
  my $path = $app->path_segments;

  if (@$path == 1 and $path->[0] eq 'session') {
    ## /session - Ensure that there is a session
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $sk = $app->bare_param ('sk') // '';
    my $sk_context = $app->bare_param ('sk_context')
        // return $app->send_error (400, reason_phrase => 'No |sk_context|');
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
        return $app->db->insert ('session', [{
          sk => $sk,
          sk_context => $sk_context,
          created => time,
          expires => time + $SessionTimeout,
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
    ##   |sk_context|, |sk|
    ##
    ##   Create an account and associate the session with it.
    ##
    ##   The session must not be associated with any account.  If
    ##   associated, an error is returned.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0]
          // return $app->send_error_json ({reason => 'Bad session'});
      my $session_data = $session_row->get ('data');
      if (defined $session_data->{account_id}) {
        return $app->send_error_json ({reason => 'Account-associated session'});
      }

      return $app->db->execute ('SELECT UUID_SHORT() AS uuid', undef, source_name => 'master')->then (sub {
        my $account_id = format_id ($_[0]->first->{uuid});
        my $time = time;
        return $app->db->insert ('account', [{
          account_id => $account_id,
          created => $time,
          name => Dongry::Type->serialize ('text', $app->text_param ('name') // $account_id),
          user_status => $app->bare_param ('user_status') // 1,
          admin_status => $app->bare_param ('admin_status') // 1,
          terms_version => $app->bare_param ('terms_version') // 0,
        }], source_name => 'master')->then (sub {
          $session_data->{account_id} = $account_id;
          return $session_row->update ({data => $session_data}, source_name => 'master');
        })->then (sub {
          return $app->send_json ({account_id => $account_id});
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
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0]
          // return $app->send_error_json ({reason => 'Bad session'});
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

      my $state = id 50;
      my $scope = join $server->{scope_separator} // ' ', grep { defined }
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

      return (defined $server->{temp_endpoint} ? Promise->new (sub {
        my ($ok, $ng) = @_;
        $cb .= $cb =~ /\?/ ? '&' : '?';
        $cb .= 'state=' . $state;

        http_oauth1_request_temp_credentials
            url_scheme => $server->{url_scheme},
            host => $server->{host},
            pathquery => $server->{temp_endpoint},
            oauth_callback => $cb,
            oauth_consumer_key => $client_id,
            client_shared_secret => $client_secret,
            params => {scope => $scope},
            auth => {host => $server->{auth_host}, pathquery => $server->{auth_endpoint}},
            timeout => $server->{timeout} || 10,
            anyevent => 1,
            cb => sub {
              my ($temp_token, $temp_token_secret, $auth_url) = @_;
              return $ng->("Temporary credentials request failed")
                  unless defined $temp_token;
              $session_data->{action}->{temp_credentials}
                  = [$temp_token, $temp_token_secret];
              $ok->($auth_url);
            };
      }) : defined $server->{auth_endpoint} ? Promise->new (sub {
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
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0]
          // return $app->send_error_json ({reason => 'Bad session'});

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
        $p = Promise->new (sub {
          my ($ok, $ng) = @_;
          http_oauth1_request_token # or die
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
              anyevent => 1,
              cb => sub {
                my ($access_token, $access_token_secret, $params) = @_;
                return $ng->("Access token request failed")
                    unless defined $access_token;
                $session_data->{$server->{name}}->{access_token} = [$access_token, $access_token_secret];
                for (@{$server->{token_res_params} or []}) {
                  $session_data->{$server->{name}}->{$_} = $params->{$_};
                }
                $ok->();
              };
        });
      } else { # OAuth 2.0
        my $code = $app->bare_param ('code') // '';
        return $app->send_error_json ({reason => 'No |code|'})
            unless length $code;
        $p = Promise->new (sub {
          my ($ok, $ng) = @_;
          http_post
              url => (($server->{url_scheme} // 'https') . '://' . $server->{host} . $server->{token_endpoint}),
              params => {
                client_id => $client_id,
                client_secret => $client_secret,
                redirect_uri => $session_data->{action}->{callback_url},
                code => $app->text_param ('code'),
                grant_type => 'authorization_code',
              },
              timeout => $server->{timeout} || 10,
              anyevent => 1,
              cb => sub {
                my (undef, $res) = @_;
                my $access_token;
                my $refresh_token;
                if ($res->content_type =~ /json/) { ## Standard
                  my $json = json_bytes2perl $res->content;
                  if (ref $json eq 'HASH' and defined $json->{access_token}) {
                    $access_token = $json->{access_token};
                    $refresh_token = $json->{refresh_token};
                  }
                } else { ## Facebook
                  my $parsed = parse_form_urlencoded_b $res->content;
                  $access_token = $parsed->{access_token}->[0];
                  $refresh_token = $parsed->{refresh_token}->[0];
                }
                return $ng->("Access token request failed")
                    unless defined $access_token;
                $session_data->{$server->{name}}->{access_token} = $access_token;
                $session_data->{$server->{name}}->{refresh_token} = $refresh_token
                    if defined $refresh_token;

                $ok->();
              };
        });
      }

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
          delete $session_data->{action};
          return $session_row->update ({data => $session_data}, source_name => 'master')->then (sub {
            return $app->send_json ({app_data => $app_data});
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
            // return $app->throw_error_json ({reason => 'Bad session'});
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
      $app->requires_request_method ({POST => 1});
      $app->requires_api_key;

      my $key = $app->bare_param ('key') // '';
      return $class->resume_session ($app)->then (sub {
        my $session_row = $_[0]
            // return $app->throw_error_json ({reason => 'Bad session'});
        my $session_data = $session_row->get ('data');
        my $account_id = $session_data->{account_id}
            // return $app->throw_error_json ({reason => 'Not a login user'});
        my $def = $session_data->{email_verifications}->{$key}
            // return $app->throw_error_json ({reason => 'Bad key'});

        return $app->db->execute ('SELECT UUID_SHORT() AS uuid', undef, source_name => 'master')->then (sub {
          my $time = time;
          return $app->db->insert ('account_link', [{
            account_link_id => $_[0]->first->{uuid},
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
          return $session_row->update ({data => $session_data}, source_name => 'master'); # XXX transaction
        })->then (sub {
          return $app->send_json ({});
        });
        # XXX account_log
      });
    }
  }

  if (@$path == 1 and $path->[0] eq 'token') {
    ## /token - Get access token of an OAuth server
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $server_name = $app->bare_param ('server') // '';
    my $server = $app->config->get_oauth_server ($server_name)
        or return $app->send_error (400, reason_phrase => 'Bad |server|');

    my $id = $app->bare_param ('account_id');
    return ((defined $id ? Promise->resolve ($id) : $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      return $session_row->get ('data')->{account_id} # or undef
          if defined $session_row;
      return undef;
    }))->then (sub {
      my $id = $_[0];
      return {} unless defined $id;
      my $json = {account_id => $id};
      return $app->db->select ('account_link', {
        account_id => Dongry::Type->serialize ('text', $id),
        service_name => Dongry::Type->serialize ('text', $server->{name}),
      }, source_name => 'master', fields => ['linked_token1', 'linked_token2'])->then (sub {
        my $r = $_[0]->first;
        if (defined $r) {
          if (defined $server->{temp_endpoint} or # OAuth 1.0
              $server->{name} eq 'ssh') {
            $json->{access_token} = [$r->{linked_token1}, $r->{linked_token2}]
                if length $r->{linked_token1} and length $r->{linked_token2};
          } else {
            $json->{access_token} = $r->{linked_token1}
                if length $r->{linked_token1};
          }
        }
        return $json;
      });
    })->then (sub {
      return $app->send_json ($_[0]);
    }));
  } # /token

  if (@$path == 1 and $path->[0] eq 'keygen') {
    ## /keygen - Generate SSH key pair
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $server_name = $app->bare_param ('server') // '';
    my $server = $app->config->get_oauth_server ($server_name)
        or return $app->send_error (400, reason_phrase => 'Bad |server|');

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      my $account_id = defined $session_row ? $session_row->get ('data')->{account_id} : undef;
      return $app->send_error_json ({reason => 'Not a login user'})
          unless defined $account_id;

      return Promise->all ([
        do {
          my $temp = File::Temp->newdir;
          my $dir = Promised::File->new_from_path ("$temp");
          my $private_file_name = "$temp/key";
          my $public_file_name = "$temp/key.pub";
          $dir->mkpath->then (sub {
            my $cmd = Promised::Command->new ([
              'ssh-keygen',
              '-t' => 'dsa',
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
        $app->db->execute ('SELECT UUID_SHORT() AS uuid', undef, source_name => 'master'),
      ])->then (sub {
        my $key = $_[0]->[0];
        my $link_id = $_[0]->[1]->first->{uuid};
        my $time = time;
        return $app->db->insert ('account_link', [{
          account_link_id => $link_id,
          account_id => Dongry::Type->serialize ('text', $account_id),
          service_name => Dongry::Type->serialize ('text', $server->{name}),
          created => $time,
          updated => $time,
          linked_id => '',
          linked_key => '',
          linked_name => '',
          linked_token1 => $key->{public},
          linked_token2 => $key->{private},
        }], source_name => 'master', duplicate => {
          linked_token1 => $app->db->bare_sql_fragment ('VALUES(linked_token1)'),
          linked_token2 => $app->db->bare_sql_fragment ('VALUES(linked_token2)'),
          updated => $app->db->bare_sql_fragment ('VALUES(updated)'),
        });
      });
    })->then (sub {
      return $app->send_json ({});
    });
  } # /keygen

  if (@$path == 1 and $path->[0] eq 'info') {
    ## /info - Current account data
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      return Promise->resolve->then (sub {
        if (defined $session_row) {
          my $id = $session_row->get ('data')->{account_id};
          if (defined $id) {
            return $app->db->select ('account', {
              account_id => Dongry::Type->serialize ('text', $id),
            }, source_name => 'master', fields => ['name', 'user_status', 'admin_status', 'terms_version'])->then (sub {
              my $r = $_[0]->first_as_row // die "Account |$id| has no data";
              my $json = {};
              $json->{account_id} = format_id $id;
              $json->{name} = $r->get ('name');
              $json->{user_status} = $r->get ('user_status');
              $json->{admin_status} = $r->get ('admin_status');
              $json->{terms_version} = $r->get ('terms_version');
              return $json;
            });
          }
        }
        return {};
      })->then (sub {
        return $class->load_linked ($app => [$_[0]]);
      })->then (sub {
        return $class->load_data ($app => $_[0]);
      })->then (sub {
        return $app->send_json ($_[0]->[0]);
      });
    });
  } # /info

  if (@$path == 1 and $path->[0] eq 'profiles') {
    ## /profiles - Account data
    ##   account_id (0..)   Account IDs
    ##   user_status (0..)  Filtering by user_status values
    ##   admin_status (0..) Filtering by admin_status values
    ##   terms_version (0..) Filtering by terms_version values
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $account_ids = $app->bare_param_list ('account_id');
    my $us = $app->bare_param_list ('user_status');
    my $as = $app->bare_param_list ('admin_status');
    my $ts = $app->bare_param_list ('terms_version');
    return ((@$account_ids ? $app->db->select ('account', {
      account_id => {-in => $account_ids},
      (@$us ? (user_status => {-in => $us}) : ()),
      (@$as ? (admin_status => {-in => $as}) : ()),
      (@$ts ? (terms_version => {-in => $ts}) : ()),
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
      return $class->load_data ($app => $_[0]);
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
      my $account_id = defined $session_row ? $session_row->get ('data')->{account_id} : undef;
      return $app->send_error_json ({reason => 'Not a login user'})
          unless defined $account_id;

      my $version = $app->bare_param ('version') || 0;
      my $dg = $app->bare_param ('downgrade');
      return $app->db->execute ('UPDATE `account` SET `terms_version` = :version WHERE `account_id` = :account_id'.($dg?'':' AND `terms_version` < :version'), {
        account_id => Dongry::Type->serialize ('text', $account_id),
        version => $version,
      }, source_name => 'master')->then (sub {
        die "UPDATE failed" unless $_[0]->row_count <= 1;
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

  if (@$path == 1 and $path->[0] eq 'robots.txt') {
    # /robots.txt
    return $app->send_plain_text ("User-agent: *\nDisallow: /");
  }

  return $app->send_error (404);
} # main

sub resume_session ($$) {
  my ($class, $app) = @_;
  my $sk = $app->bare_param ('sk') // '';
  return (length $sk ? $app->db->select ('session', {
    sk => $sk,
    sk_context => $app->bare_param ('sk_context') // '',
    created => {'>', time - $SessionTimeout},
  }, source_name => 'master')->then (sub {
    return $_[0]->first_as_row; # or undef
  }) : Promise->resolve (undef));
} # resume_session

sub delete_old_sessions ($$) {
  return $_[1]->db->execute ('DELETE FROM `session` WHERE created < ?', {
    created => time - $SessionTimeout,
  });
} # delete_old_sessions

sub get_resource_owner_profile ($$%) {
  my ($class, $app, %args) = @_;
  my $server = $args{server} or die;
  my $service = $server->{name};
  my $session_data = $args{session_data} or die;
  return unless defined $server->{profile_endpoint};

  return Promise->new (sub {
    my ($ok, $ng) = @_;
    my %param;
    if ($server->{auth_scheme} eq 'header') {
      $param{header_fields}->{Authorization} = 'Bearer ' . $session_data->{$service}->{access_token};
    } elsif ($server->{auth_scheme} eq 'query') {
      $param{params}->{access_token} = $session_data->{$service}->{access_token};
    } elsif ($server->{auth_scheme} eq 'token') {
      $param{header_fields}->{Authorization} = 'token ' . $session_data->{$service}->{access_token};
    } elsif ($server->{auth_scheme} eq 'oauth1') {
      my $client_id = $app->config->get ($server->{name} . '.client_id.' . $args{sk_context}) //
                      $app->config->get ($server->{name} . '.client_id');
      my $client_secret = $app->config->get ($server->{name} . '.client_secret.' . $args{sk_context}) //
                          $app->config->get ($server->{name} . '.client_secret');

      $param{oauth} = [$client_id, $client_secret,
                       @{$session_data->{$service}->{access_token}}];
      $param{params}->{user_id} = $session_data->{$service}->{user_id}
          if $server->{name} eq 'twitter';
    }
    http_get
        url => (($server->{url_scheme} // 'https') . '://' . ($server->{profile_host} // $server->{host}) . $server->{profile_endpoint}),
        %param,
        timeout => $server->{timeout} || 30,
        anyevent => 1,
        cb => sub {
          my (undef, $res) = @_;
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } else {
            $ng->($res->code);
          }
        };
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
      $token1 = $session_data->{$service}->{access_token} // '';
    }
    if (@$links == 0) { # new account
      return $app->db->execute ('SELECT UUID_SHORT() AS account_id, UUID_SHORT() AS link_id', undef, source_name => 'master')->then (sub {
        my $uuids = $_[0]->first;
        $uuids->{account_id} = format_id $uuids->{account_id};
        $uuids->{account_link_id} = format_id $uuids->{account_link_id};
        my $time = time;
        my $account = {account_id => $uuids->{account_id},
                       user_status => 1, admin_status => 1,
                       terms_version => 0};
        my $name = $link->{name};
        $name = $account->{account_id} unless defined $name and length $name;
        return $app->db->execute ('INSERT INTO account (account_id, created, user_status, admin_status, terms_version, name) VALUES (:account_id, :created, :user_status, :admin_status, :terms_version, :name)', {
          created => $time,
          %$account,
          name => Dongry::Type->serialize ('text', $name),
        }, source_name => 'master', table_name => 'account')->then (sub {
          return $app->db->execute ('INSERT INTO account_link (account_link_id, account_id, service_name, created, updated, linked_name, linked_id, linked_key, linked_token1, linked_token2, linked_email, linked_data) VALUES (:account_link_id, :account_id, :service_name, :created, :updated, :linked_name, :linked_id, :linked_key:nullable, :linked_token1, :linked_token2, :linked_email, :linked_data)', {
            account_link_id => $uuids->{link_id},
            account_id => $uuids->{account_id},
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
            my $account_link = {account_link_id => $uuids->{link_id}};
            return [$account, $account_link];
          });
        })->then (sub {
          my $return = $_[0];
          return $return unless $session_data->{action}->{create_email_link};
          my $addr = $link->{email} // '';
          return $return unless $addr =~ /\A[\x21-\x3F\x41-\x7E]+\@[\x21-\x3F\x41-\x7E]+\z/;
          my $email_id = sha1_hex $addr;
          return $app->db->execute ('SELECT UUID_SHORT() AS uuid', undef, source_name => 'master')->then (sub {
            my $time = time;
            return $app->db->insert ('account_link', [{
              account_link_id => $_[0]->first->{uuid},
              account_id => Dongry::Type->serialize ('text', $account->{account_id}),
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
            }], source_name => 'master', duplicate => 'replace');
          })->then (sub { return $return });
        });
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
          updated => time,
        }, source_name => 'master'),
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
    $token1 = $session_data->{$service}->{access_token} // '';
  }

  return $app->db->execute ('SELECT UUID_SHORT() AS uuid', undef, source_name => 'master')->then (sub {
    my $link_id = $_[0]->first->{uuid};
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
    });
  });
} # link_account

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
  push @field, 'service_name';
  push @field, 'account_id';

  return $app->db->select ('account_link', {
    account_id => {-in => \@account_id},
  }, fields => \@field, source_name => 'master')->then (sub {
    for (@{$_[0]->all}) {
      my $json = $account_id_to_json->{$_->{account_id}};
      my $link = $json->{links}->{$_->{service_name}, $_->{linked_id}} ||= {};
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
    }
    return $items;
  });
} # load_linked

sub load_data ($$$) {
  my ($class, $app, $items) = @_;

  my $account_id_to_json = {};
  my @account_id = map {
    $account_id_to_json->{$_->{account_id}} = $_;
    Dongry::Type->serialize ('text', $_->{account_id});
  } grep { defined $_->{account_id} } @$items;
  return $items unless @account_id;

  my @field = map { Dongry::Type->serialize ('text', $_) } $app->text_param_list ('with_data')->to_list;
  return $items unless @field;

  return $app->db->select ('account_data', {
    account_id => {-in => \@account_id},
    key => {-in => \@field},
  }, source_name => 'master')->then (sub {
    for (@{$_[0]->all}) {
      my $json = $account_id_to_json->{$_->{account_id}};
      $json->{data}->{$_->{key}} = Dongry::Type->parse ('text', $_->{value})
          if defined $_->{value} and length $_->{value};
    }
    return $items;
  });
} # load_data

1;

=head1 LICENSE

Copyright 2007-2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
