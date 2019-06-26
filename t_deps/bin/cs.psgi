#!/usr/bin/perl
use strict;
use warnings;
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
