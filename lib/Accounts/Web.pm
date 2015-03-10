package Accounts::Web;
use strict;
use warnings;
use Path::Tiny;
use Promise;
use JSON::PS;
use Wanage::URL;
use Wanage::HTTP;
use Accounts::AppServer;
use Web::UserAgent::Functions qw(http_post);
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

    return $class->resume_session ($app, no_session_url => '/oauth?server=' . percent_encode_c $app->bare_param ('server'))->then (sub { # XXXtransaction
      my $session_row = $_[0];

      my $cb = $app->http->url->resolve_string ('/oauth/cb')->stringify;
      my $state = id 50;
      my $scope = $server->{login_scope};

      my $session_data = $session_row->get ('data');
      $session_data->{action} = {endpoint => 'oauth',
                                 server => $server->{name},
                                 state => $state};

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
        delete $session_data->{action};
        return $session_row->update ({data => $session_data}, source_name => 'master')->then (sub {
          return $app->send_redirect ('/oauth');
        });
      })->then (sub {
        return $class->delete_old_sessions ($app);
      });
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

my $SessionTimeout = 60*30;

sub start_session ($$) {
  my ($class, $app) = @_;
  my $sk = $app->http->request_cookies->{sk} // '';
  return (length $sk ? $app->db->execute ('SELECT session_id FROM `session` WHERE session_id = ? AND created > ?', {
    session_id => $sk,
    created => time - $SessionTimeout,
  }, source_name => 'master')->then (sub {
    my $v = $_[0]->first;
    if (defined $v) {
      return $v->{session_id};
    } else {
      return undef;
    }
  }) : Promise->resolve (undef))->then (sub {
    my $sk = $_[0];
    if (defined $sk) {
      return {sk => $sk};
    } else {
      $sk = id 100;
      return $app->db->execute ('INSERT INTO session (session_id, created, data) VALUES (:session_id, :created, "{}")', {
        session_id => $sk,
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
  return (defined $sk ? $app->db->execute ('SELECT session_id, data FROM `session` WHERE session_id = ? AND created > ?', {
    session_id => $sk,
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

1;

=head1 LICENSE

Copyright 2007-2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
