#!/usr/bin/perl
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
      } elsif ($path eq '/oauth2r/token') {
        my $params = $http->request_body_params;
        if ($params->{grant_type}->[0] eq 'authorization_code') {
          my $session = $Sessions->{$params->{code}->[0]};
          if (not defined $session) {
            $http->set_status (400);
            $http->send_response_body_as_text ("Bad |code|");
          } elsif ($params->{redirect_uri}->[0] eq $session->{callback} and
                   $params->{client_id}->[0] =~ /\A\Q$ClientID\E\.oauth2(\.\w+|)\z/ and
                   $params->{client_secret}->[0] =~ /\A\Q$ClientSecret\E\.oauth2(\Q$1\E)\z/) {
            my $token = rand;
            my $no_id = $session->{account_no_id};
            my $refresh_token = rand;
            my $expires = time + 1000;
            my $session = $Sessions->{$token} = $Sessions->{$refresh_token} = {
              access_token => $token,
              refresh_token => $refresh_token,
              expires_at => $expires,
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
              refresh_token => $session->{refresh_token}.$1,
              expires_at => $session->{expires_at},
            });
            delete $Sessions->{$params->{code}->[0]};
          } else {
            $http->send_response_body_as_text (Dumper {
              _ => 'Bad params',
              params => $params,
            });
          }
        } elsif ($params->{grant_type}->[0] eq 'refresh_token') {
          my $session = $Sessions->{$params->{refresh_token}->[0]};
          if (not defined $session) {
            $http->set_status (400);
            $http->send_response_body_as_text ("Bad |refresh_token|");
          } elsif ($params->{client_id}->[0] =~ /\A\Q$ClientID\E\.oauth2(\.\w+|)\z/ and
                   $params->{client_secret}->[0] =~ /\A\Q$ClientSecret\E\.oauth2(\Q$1\E)\z/) {
            delete $Sessions->{$session->{access_token}};
            delete $Sessions->{$session->{refresh_token}};
            $session->{access_token} = rand;
            $session->{refresh_token} = rand;
            my $expires = time + 1000;
            $session->{expires_at} = $expires;
            $Sessions->{$session->{access_token}} = $session;
            $Sessions->{$session->{refresh_token}} = $session;
            $http->set_response_header ('Content-Type' => 'application/json');
            $http->send_response_body_as_text (perl2json_bytes +{
              access_token => $session->{access_token}.$1,
              refresh_token => $session->{refresh_token}.$1,
              expires_at => $session->{expires_at},
            });
          } else {
            $http->send_response_body_as_text (Dumper {
              _ => 'Bad params',
              params => $params,
            });
          }
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
