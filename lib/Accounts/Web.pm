package Accounts::Web;
use strict;
use warnings;
use Path::Tiny;
use Promise;
use JSON::PS;
use Wanage::URL;
use Wanage::HTTP;
use Dongry::Type;
use Dongry::SQL;
use Accounts::AppServer;
use Web::UserAgent::Functions qw(http_post http_get);
use Web::UserAgent::Functions::OAuth;

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
      return Promise->resolve ($class->main ($app))->then (sub {
        return $app->shutdown;
      }, sub {
        my $error = $_[0];
        return $app->shutdown->then (sub { die $error });
      });
    });
  };
} # psgi_app

sub id ($) {
  my $key = '';
  $key .= ['A'..'Z', 'a'..'z', 0..9]->[rand 36] for 1..$_[0];
  return $key;
} # id

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

  if (@$path == 1 and $path->[0] eq 'login') {
    ## /login - Start OAuth flow to associate session with account
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0]
          // return $app->send_error_json ({reason => 'Bad session'});
      my $session_data = $session_row->get ('data');

      my $server = $app->config->get_oauth_server ($app->bare_param ('server'))
          or return $app->throw_error (400, reason_phrase => 'Bad |server|');
      ## Application must specify a legal |callback_url| in the
      ## context of the application.
      my $cb = $app->text_param ('callback_url')
          // return $app->throw_error (400, reason_phrase => 'Bad |callback_url|');

      my $state = id 50;
      my $scope = join $server->{scope_separator} // ' ', grep { defined }
          $server->{login_scope},
          @{$app->text_param_list ('server_scope')};
      $session_data->{action} = {endpoint => 'oauth',
                                 server => $server->{name},
                                 callback_url => $cb,
                                 state => $state};

      return (defined $server->{temp_endpoint} ? Promise->new (sub {
        my ($ok, $ng) = @_;
        $cb .= $cb =~ /\?/ ? '&' : '?';
        $cb .= 'state=' . $state;
        http_oauth1_request_temp_credentials
            host => $server->{host},
            pathquery => $server->{temp_endpoint},
            oauth_callback => $cb,
            oauth_consumer_key => $server->{client_id},
            client_shared_secret => $server->{client_secret},
            params => {scope => $scope},
            auth => {pathquery => $server->{auth_endpoint}},
            timeout => 30,
            anyevent => 1,
            cb => sub {
              my ($temp_token, $temp_token_secret, $auth_url) = @_;
              return $ng->("Temporary credentials request failed")
                  unless defined $temp_token;
              $session_data->{action}->{temp_credentials}
                  = [$temp_token, $temp_token_secret];
              $ok->($auth_url);
            };
      }) : Promise->new (sub {
        my ($ok, $ng) = @_;
        my $auth_url = q<https://> . ($server->{auth_host} // $server->{host}) . ($server->{auth_endpoint}) . '?' . join '&', map {
          (percent_encode_c $_->[0]) . '=' . (percent_encode_c $_->[1])
        } (
          [client_id => $server->{client_id}],
          [redirect_uri => $cb],
          [response_type => 'code'],
          [state => $state],
          [scope => $scope],
        );
        $ok->($auth_url);
      }))->then (sub {
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

      return ((defined $session_data->{action}->{temp_credentials} ? Promise->new (sub {
        my ($ok, $ng) = @_;
        http_oauth1_request_token # or die
            host => $server->{host},
            pathquery => $server->{token_endpoint},
            oauth_consumer_key => $server->{client_id},
            client_shared_secret => $server->{client_secret},
            temp_token => $session_data->{action}->{temp_credentials}->[0],
            temp_token_secret => $session_data->{action}->{temp_credentials}->[1],
            oauth_token => $app->bare_param ('oauth_token'),
            oauth_verifier => $app->bare_param ('oauth_verifier'),
            timeout => 30,
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
      }) : Promise->new (sub {
        my ($ok, $ng) = @_;
        http_post
            url => ('https://' . $server->{host} . $server->{token_endpoint}),
            params => {
              client_id => $server->{client_id},
              client_secret => $server->{client_secret},
              redirect_uri => $session_data->{action}->{callback_url},
              code => $app->text_param ('code'),
              grant_type => 'authorization_code',
            },
            timeout => 30,
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
      }))->then (sub {
        return Promise->resolve ($class->get_resource_owner_profile (
          $app,
          server => $server,
          session_data => $session_data,
        ))->then (sub {
          return $class->create_account (
            $app,
            server => $server,
            session_data => $session_data,
          );
        })->then (sub {
          delete $session_data->{action};
          return $session_row->update ({data => $session_data}, source_name => 'master')->then (sub {
            return $app->send_json ({});
          });
        });
      }, sub {
        return $app->send_error_json ({reason => 'OAuth token endpoint failed',
                                       error_for_dev => "$_[0]"});
      })->then (sub {
        return $class->delete_old_sessions ($app);
      }));
    });
  } # /cb

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
    }))->then (sub {
      my $id = $_[0];
      my $json = {};
      return $json unless defined $id;
      return $app->db->select ('account_link', {
        account_id => Dongry::Type->serialize ('text', $id),
        service_name => $server->{name},
      }, source_name => 'master', fields => ['linked_token1', 'linked_token2'])->then (sub {
        my $r = $_[0]->first;
        if (defined $r) {
          if (defined $server->{temp_endpoint}) { # OAuth 1.0
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

  if (@$path == 1 and $path->[0] eq 'info') {
    ## /info - Current account data
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      my $json = {};
      return Promise->resolve->then (sub {
        if (defined $session_row) {
          my $id = $session_row->get ('data')->{account_id};
          if (defined $id) {
            return $app->db->select ('account', {
              account_id => Dongry::Type->serialize ('text', $id),
            }, source_name => 'master', fields => ['name'])->then (sub {
              my $r = $_[0]->first_as_row // die "Account |$id| has no data";
              $json->{account_id} = $id;
              $json->{name} = $r->get ('name');
            });
          }
        }
      })->then (sub {
        return $app->send_json ($json);
      });
    });
  } # /info

  if (@$path == 1 and $path->[0] eq 'profiles') {
    ## /profiles - Public account data
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $account_ids = $app->bare_param_list ('account_id');
    return ((@$account_ids ? $app->db->select ('account', {
      account_id => {-in => $account_ids},
    }, source_name => 'master', fields => ['account_id', 'name'])->then (sub {
      return $_[0]->all_as_rows->to_a;
    }) : Promise->resolve ([]))->then (sub {
      return $app->send_json ({accounts => {map { $_->get ('account_id') => {
        account_id => $_->get ('account_id'),
        name => $_->get ('name'),
      } } @{$_[0]}}});
    }));
  } # /profiles

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
        $accounts->{$row->get ('account_id')}->{services}->{$row->get ('service_name')} = $v;
      }
      # XXX filter by account.user_status && account.admin_status
      return $app->send_json ({accounts => $accounts});
    }));
  } # /search

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
    if ($server->{auth_scheme} eq 'token') {
      $param{header_fields}->{Authorization} = 'token ' . $session_data->{$service}->{access_token};
    }
    http_get
        url => ('https://' . ($server->{profile_host} // $server->{host}) . $server->{profile_endpoint}),
        %param,
        timeout => 30,
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
  });
} # get_resource_owner_profile

sub create_account ($$%) {
  my ($class, $app, %args) = @_;
  my $server = $args{server} or die;
  my $service = $server->{name};
  my $session_data = $args{session_data} or die;

  return $app->send_error (400, reason_phrase => 'Non-loginable |service|')
      unless defined $server->{linked_id_field};

  my $id = $session_data->{$service}->{$server->{linked_id_field}};
  return $app->send_error (400, reason_phrase => 'Non-loginable server account')
      unless defined $id and length $id;
  $id = Dongry::Type->serialize ('text', $id);
  my $link_id = '';
  #my $link_id = $app->bare_param ('account_link_id') // '';
  return ((length $link_id ? $app->db->execute ('SELECT account_link_id, account_id FROM account_link WHERE account_link_id = ? AND service_name = ? AND linked_id = ?', {
    account_link_id => $link_id,
    service_name => $service,
    linked_id => $id,
  }, source_name => 'master') : $app->db->execute ('SELECT account_link_id, account_id FROM account_link WHERE service_name = ? AND linked_id = ?', {
    service_name => $service,
    linked_id => $id,
  }, source_name => 'master'))->then (sub {
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
        $uuids->{account_id} .= '';
        $uuids->{account_link_id} .= '';
        my $time = time;
        my $name = $uuids->{account_id};
        my $linked_name = $session_data->{$service}->{$server->{linked_name_field} // ''} // '';
        $name = $linked_name if length $linked_name;
        my $account = {account_id => $uuids->{account_id},
                       user_status => 1, admin_status => 1,
                       terms_version => 0};
        return $app->db->execute ('INSERT INTO account (account_id, created, user_status, admin_status, terms_version, name) VALUES (:account_id, :created, :user_status, :admin_status, :terms_version, :name)', {
          created => $time,
          %$account,
          name => Dongry::Type->serialize ('text', $name),
        }, source_name => 'master', table_name => 'account')->then (sub {
          return $app->db->execute ('INSERT INTO account_link (account_link_id, account_id, service_name, created, updated, linked_name, linked_id, linked_key, linked_token1, linked_token2) VALUES (:account_link_id, :account_id, :service_name, :created, :updated, :linked_name, :linked_id, :linked_key, :linked_token1, :linked_token2)', {
            account_link_id => $uuids->{link_id},
            account_id => $uuids->{account_id},
            service_name => Dongry::Type->serialize ('text', $server->{name}),
            created => $time,
            updated => $time,
            linked_name => Dongry::Type->serialize ('text', $linked_name),
            linked_id => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_id_field} // ''} // ''),
            linked_key => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_key_field} // ''} // ''),
            linked_token1 => Dongry::Type->serialize ('text', $token1),
            linked_token2 => Dongry::Type->serialize ('text', $token2),
          }, source_name => 'master', table_name => 'account_link')->then (sub {
            my $account_link = {account_link_id => $uuids->{link_id}};
            return [$account, $account_link];
          });
        });
      });
    } elsif (@$links == 1) { # existing account
      my $time = time;
      my $account_id = $links->[0]->{account_id};
      my $name = $account_id;
      my $linked_name = $session_data->{$service}->{$server->{linked_name_field} // ''} // '';
      $name = $linked_name if length $linked_name;
      return Promise->all ([
        $app->db->execute ('UPDATE account SET name = ? WHERE account_id = ?', {
          name => Dongry::Type->serialize ('text', $name),
          account_id => $account_id,
        }, source_name => 'master')->then (sub {
          return $app->db->execute ('SELECT account_id,user_status,admin_status,terms_version FROM account WHERE account_id = ?', {
            account_id => $account_id,
          }, source_name => 'master', table_name => 'account');
        }),
        $app->db->execute ('UPDATE account_link SET linked_name = ?, linked_id = ?, linked_key = ?, linked_token1 = ?, linked_token2 = ?, updated = ? WHERE account_link_id = ? AND account_id = ?', {
          account_link_id => $links->[0]->{account_link_id},
          account_id => $account_id,
          linked_name => Dongry::Type->serialize ('text', $linked_name),
          linked_id => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_id_field} // ''} // ''),
          linked_key => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_key_field} // ''} // ''),
          linked_token1 => Dongry::Type->serialize ('text', $token1),
          linked_token2 => Dongry::Type->serialize ('text', $token2),
          updated => time,
        }, source_name => 'master'),
      ])->then (sub {
        return [$_[0]->[0]->first, {account_link_id => $links->[0]->{account_link_id}}];
      });
    } else { # multiple account links
      die "XXX Not implemented yet";
    }
  }))->then (sub {
    my ($account, $account_link) = @{$_[0]};
    unless ($account->{user_status} == 1) {
      die "XXX Disabled account";
    }
    unless ($account->{admin_status} == 1) {
      die "XXX Account suspended";
    }
    my $expected_version = 0;
    if ($account->{terms_version} < $expected_version) {
      die "XXX Not implemented yet";
    }
    $session_data->{account_id} = ''.$account->{account_id};
  });
} # create_account

1;

=head1 LICENSE

Copyright 2007-2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
