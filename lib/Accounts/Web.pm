package Accounts::Web;
use strict;
use warnings;
use Path::Tiny;
use Promise;
use JSON::PS;
use Wanage::URL;
use Wanage::HTTP;
use Dongry::Type;
use Accounts::AppServer;
use Web::UserAgent::Functions qw(http_post);
use Web::UserAgent::Functions::OAuth;

my $SessionTimeout = 60*30;
my $ATSTimeout = 60*30;

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
      #XXX
      #my $origin = $app->http->url->ascii_origin;
      #if ($origin eq $app->config->{web_origin}) {
        return Promise->resolve ($class->main ($app))->then (sub {
          return $app->shutdown;
        }, sub {
          my $error = $_[0];
          return $app->shutdown->then (sub { die $error });
        });
      #} else {
      #  return $app->send_error (400, reason_phrase => 'Bad |Host:|');
      #}
    });
  };
} # psgi_app

sub id ($) {
  my $key = '';
  $key .= ['A'..'Z', 'a'..'z', 0..9]->[rand 36] for 1..$_[0];
  return $key;
} # id

sub main ($$) {
  my ($class, $app) = @_;
  my $path = $app->path_segments;

  if (@$path == 1 and $path->[0] eq '') {
    # /

    # XXX
    return $app->db->execute ('show tables')->then (sub {
      use Data::Dumper;
      return $app->send_plain_text (Dumper $_[0]->all);
    });
  }

  if (@$path == 1 and $path->[0] eq 'oauth') {
    # /oauth
    return $class->start_session ($app)->then (sub {
      $app->http->set_response_header ('Content-Type' => 'text/html; charset=utf-8');
      $app->http->send_response_body_as_text (sprintf q{
        <form action=/oauth/start method=post>
          <button type=submit name=server value=twitter>Twitter</button>
          <button type=submit name=server value=hatena>Hatena</button>
          <button type=submit name=server value=google>Google</button>
          <button type=submit name=server value=facebook>Facebook</button>
          <button type=submit name=server value=github>GitHub</button>
          <button type=submit name=server value=bitbucket>Bitbucket</button>
          <input type=hidden name=next_action value=login>
        </form>
      });
      return $app->http->close_response_body;
    });
  }

  if (@$path == 2 and $path->[0] eq 'oauth' and $path->[1] eq 'start') {
    # /oauth/start
    $app->requires_request_method ({POST => 1});
    # XXX CSRF

    my $server = $app->config->get_oauth_server ($app->bare_param ('server'))
        or return $app->send_error (404, reason_phrase => 'Bad |server|');

    my $next_action = $app->bare_param ('next_action') // '';
    return $app->send_error (400, reason_phrase => 'Bad |next_action|')
        unless {login => 1}->{$next_action};

    return $class->resume_session ($app, no_session_url => '/oauth?server=' . percent_encode_c $app->bare_param ('server'))->then (sub { # XXXtransaction
      my $session_row = $_[0];

      my $cb = $app->http->url->resolve_string ('/oauth/cb')->stringify;
      my $state = id 50;
      my $scope = $server->{login_scope};

      my $session_data = $session_row->get ('data');
      $session_data->{action} = {endpoint => 'oauth',
                                 server => $server->{name},
                                 state => $state,
                                 next => $next_action};

      return (defined $server->{temp_endpoint} ? Promise->new (sub {
        my ($ok, $ng) = @_;
        $cb .= '?state=' . $state;
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
          return $app->send_redirect ($auth_url);
        });
      })->then (sub {
        return $class->delete_old_sessions ($app);
      });
    });
  }

  if (@$path == 2 and $path->[0] eq 'oauth' and $path->[1] eq 'cb') {
    # /oauth/cb
    return $class->resume_session ($app, no_session_url => '/oauth?server=' . percent_encode_c $app->bare_param ('server'))->then (sub { # XXXtransaction
      my $session_row = $_[0];

      my $session_data = $session_row->get ('data');
      return $app->send_error (400, reason_phrase => 'Bad callback call')
          unless 'oauth' eq ($session_data->{action}->{endpoint} // '');

      my $actual_state = $app->bare_param ('state') // '';
      return $app->throw_error (400, reason_phrase => 'Bad |state|')
          unless length $actual_state and
                 $actual_state eq $session_data->{action}->{state};

      my $server = $app->config->get_oauth_server
          ($session_data->{action}->{server})
          or $app->throw_error (500);

      return (defined $session_data->{action}->{temp_credentials} ? Promise->new (sub {
        my ($ok, $ng) = @_;
        http_oauth1_request_token # or die
            host => $server->{host},
            pathquery => $server->{token_endpoint},
            oauth_consumer_key => $server->{client_id},
            client_shared_secret => $server->{client_secret},
            temp_token => $session_data->{action}->{temp_credentials}->[0],
            temp_token_secret => $session_data->{action}->{temp_credentials}->[1],
            current_request_url => $app->http->url->stringify,
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
        my $cb = $app->http->url->resolve_string ('/oauth/cb')->stringify;
        my $code = $app->text_param ('code')
            // return $app->throw_error (400, reason_phrase => 'Bad |code|');
        http_post
            url => ('https://' . $server->{host} . $server->{token_endpoint}),
            params => {
              client_id => $server->{client_id},
              client_secret => $server->{client_secret},
              redirect_uri => $cb,
              code => $code,
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
        my $next = (delete $session_data->{action})->{next} // '';
        return $app->send_error (400, reason_phrase => 'Bad |next_action|')
            unless $next eq 'login';
        return Promise->resolve ($class->create_account (
          $app,
          server => $server,
          session_data => $session_data,
        ))->then (sub {
          return $session_row->update ({data => $session_data}, source_name => 'master')->then (sub {
            return $app->send_redirect ('/oauth');
          });
        });
      })->then (sub {
        return $class->delete_old_sessions ($app);
      });
    });
  }

  if (@$path == 2 and $path->[0] eq 'ats' and $path->[1] eq 'create') {
    # /ats/create
    $app->requires_request_method ({POST => 1});

    my $auth = $app->http->request_auth;
    unless (defined $auth->{auth_scheme} and
            $auth->{auth_scheme} eq 'bearer' and
            length $auth->{token} and
            $auth->{token} eq $app->config->get ('ats.bearer')) {
      $app->http->set_status (401);
      $app->http->set_response_auth ('Bearer');
      $app->http->set_response_header
          ('Content-Type' => 'text/plain; charset=us-ascii');
      $app->http->send_response_body_as_ref (\'401 Authorization required');
      $app->http->close_response_body;
      return;
    }

    my $app_name = $app->text_param ('app_name')
        // return $app->send_error (400, reason_phrase => 'Bad |app_name|');
    my $url = $app->text_param ('callback_url')
        // return $app->send_error (400, reason_phrase => 'Bad |callback_url|');

    my $atsk = id 100;
    my $state = id 50;
    return $app->db->insert ('app_temp_session', [{
      atsk => $atsk,
      app_name => Dongry::Type->serialize ('text', $app_name),
      created => time,
      data => Dongry::Type->serialize ('json', {
        callback_url => $url,
        state => $state,
      }),
    }], source_name => 'master')->then (sub {
      return $app->send_json ({
        atsk => $atsk,
        state => $state,
      });
    });
  }

  if (@$path == 2 and $path->[0] eq 'ats' and $path->[1] eq 'get') {
    # /ats/get
    $app->requires_request_method ({POST => 1});

    my $auth = $app->http->request_auth;
    unless (defined $auth->{auth_scheme} and
            $auth->{auth_scheme} eq 'bearer' and
            length $auth->{token} and
            $auth->{token} eq $app->config->get ('ats.bearer')) {
      $app->http->set_status (401);
      $app->http->set_response_auth ('Bearer');
      $app->http->set_response_header
          ('Content-Type' => 'text/plain; charset=us-ascii');
      $app->http->send_response_body_as_ref (\'401 Authorization required');
      $app->http->close_response_body;
      return;
    }

    my $app_name = $app->text_param ('app_name')
        // return $app->send_error (400, reason_phrase => 'Bad |app_name|');
    my $atsk = $app->text_param ('atsk')
        // return $app->send_error (403, reason_phrase => 'Bad |atsk|');
    my $state = $app->text_param ('state')
        // return $app->send_error (403, reason_phrase => 'Bad |state|');

    return $app->db->select ('app_temp_session', {
      atsk => Dongry::Type->serialize ('text', $atsk),
      app_name => Dongry::Type->serialize ('text', $app_name),
    }, source_name => 'master')->then (sub {
      my $row = $_[0]->first_as_row
          or return $app->send_error (404, reason_phrase => 'Bad |atsk|');
      my $data = $row->get ('data');
      unless (defined $data->{state} and
              length $data->{state} and
              $data->{state} eq $state) {
        return $app->send_error (403, reason_phrase => 'Bad |state|');
      }

      return $row->delete (source_name => 'master')->then (sub {
        return $app->send_json ({
          callback_url => $data->{callback_url},
        });
      });
    })->then (sub {
      return $app->db->execute ('DELETE FROM app_temp_session WHERE created < ?', {
        created => time - $ATSTimeout,
      }, source_name => 'master');
    });
  }


  if (@$path == 2 and
      {js => 1, css => 1, data => 1, images => 1, fonts => 1}->{$path->[0]} and
      $path->[1] =~ /\A[0-9A-Za-z_-]+\.(js|css|jpe?g|gif|png|json|ttf|otf|woff)\z/) {
    # /js/* /css/* /images/* /data/*
    return $app->send_file ("$path->[0]/$path->[1]", {
      js => 'text/javascript; charset=utf-8',
      css => 'text/css; charset=utf-8',
      jpeg => 'image/jpeg',
      jpg => 'image/jpeg',
      gif => 'image/gif',
      png => 'image/png',
      json => 'application/json',
    }->{$1});
  }

  return $app->send_error (404);
} # main

sub start_session ($$) {
  my ($class, $app) = @_;
  my $sk = $app->http->request_cookies->{sk} // '';
  return (length $sk ? $app->db->execute ('SELECT sk FROM `session` WHERE sk = ? AND created > ?', {
    sk => $sk,
    created => time - $SessionTimeout,
  }, source_name => 'master')->then (sub {
    my $v = $_[0]->first;
    if (defined $v) {
      return $v->{sk};
    } else {
      return undef;
    }
  }) : Promise->resolve (undef))->then (sub {
    my $sk = $_[0];
    if (defined $sk) {
      return {sk => $sk};
    } else {
      $sk = id 100;
      return $app->db->execute ('INSERT INTO session (sk, created, data) VALUES (:sk, :created, "{}")', {
        sk => $sk,
        created => time,
      }, source_name => 'master')->then (sub {
        $app->http->set_response_cookie
            (sk => $sk,
             expires => time + $SessionTimeout,
             #secure => $cookiesecure, # XXX
             #domain => $cookiedomain, # XXX
             path => q</>,
             httponly => 1);
        return {sk => $sk, new => 1};
      }); # or duplicate rejection
    }
  });
} # start_session

sub resume_session ($$;%) {
  my ($class, $app, %args) = @_;
  my $sk = $app->http->request_cookies->{sk};
  return (defined $sk ? $app->db->execute ('SELECT sk, data FROM `session` WHERE sk = ? AND created > ?', {
    sk => $sk,
    created => time - $SessionTimeout,
  }, source_name => 'master', table_name => 'session')->then (sub {
    return $_[0]->first_as_row; # or undef
  }) : Promise->resolve (undef))->then (sub {
    if (not defined $_[0]) {
      if (defined $args{no_session_url}) {
        return $app->throw_redirect ($args{no_session_url});
      } else {
        return $app->throw_error (400, reason_phrase => 'Invalid session');
      }
    }
    return $_[0];
  });
} # resume_session

sub delete_old_sessions ($$) {
  return $_[1]->db->execute ('DELETE FROM `session` WHERE created < ?', {
    created => time - $SessionTimeout,
  });
} # delete_old_sessions

sub create_account ($$%) {
  my ($class, $app, %args) = @_;
  my $server = $args{server} or die;
  my $service = $server->{name};

  return $app->send_error (400, reason_phrase => 'Non-loginable |service|')
      unless defined $server->{linked_id_field};

  my $session_data = $args{session_data} or die;

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
    if (@$links == 0) { # new account
      return $app->db->execute ('SELECT UUID_SHORT() AS account_id, UUID_SHORT() AS link_id', undef, source_name => 'master')->then (sub {
        my $uuids = $_[0]->first;
        $uuids->{account_id} .= '';
        $uuids->{account_link_id} .= '';
        my $time = time;
        my $name = $uuids->{account_id};
        my $account = {account_id => $uuids->{account_id},
                       user_status => 1, admin_status => 1,
                       terms_version => 0};
        return $app->db->execute ('INSERT INTO account (account_id, created, user_status, admin_status, terms_version, name) VALUES (:account_id, :created, :user_status, :admin_status, :terms_version, :name)', {
          created => $time,
          %$account,
          name => Dongry::Type->serialize ('text', $name),
        }, source_name => 'master', table_name => 'account')->then (sub {
          return $app->db->execute ('INSERT INTO account_link (account_link_id, account_id, service_name, created, updated, linked_name, linked_id, linked_token1, linked_token2) VALUES (:account_link_id, :account_id, :service_name, :created, :updated, :linked_name, :linked_id, :linked_token1, :linked_token2)', {
            account_link_id => $uuids->{link_id},
            account_id => $uuids->{account_id},
            service_name => Dongry::Type->serialize ('text', $server->{name}),
            created => $time,
            updated => $time,
            linked_name => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_name_field} // ''} // ''),
            linked_id => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_id_field} // ''} // ''),
            linked_token1 => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_token1_field} // ''} // ''),
            linked_token2 => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_token2_field} // ''} // ''),
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
      return Promise->all ([
        $app->db->execute ('UPDATE account SET name = ? WHERE account_id = ?', {
          name => Dongry::Type->serialize ('text', $name),
          account_id => $account_id,
        }, source_name => 'master')->then (sub {
          return $app->db->execute ('SELECT account_id,user_status,admin_status,terms_version FROM account WHERE account_id = ?', {
            account_id => $account_id,
          }, source_name => 'master', table_name => 'account');
        }),
        $app->db->execute ('UPDATE account_link SET linked_name = ?, linked_id = ?, linked_token1 = ?, linked_token2 = ?, updated = ? WHERE account_link_id = ? AND account_id = ?', {
          account_link_id => $links->[0]->{account_link_id},
          account_id => $account_id,
          linked_name => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_name_field} // ''} // ''),
          linked_id => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_id_field} // ''} // ''),
          linked_token1 => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_token1_field} // ''} // ''),
          linked_token2 => Dongry::Type->serialize ('text', $session_data->{$service}->{$server->{linked_token2_field} // ''} // ''),
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
