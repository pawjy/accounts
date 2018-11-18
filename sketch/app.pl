use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->child ('t_deps/modules/*/lib');
use MIME::Base64;
use Web::UserAgent::Functions;
use Promised::Plackup;
use AnyEvent;

my $token = decode_base64 shift;
my $cv = AE::cv;

my $plackup = Promised::Plackup->new;
$plackup->plackup ('./plackup');
$plackup->envs->{API_TOKEN} = $token;
$plackup->set_option ('--port' => 1705);
$plackup->set_app_code (q{
  use Wanage::HTTP;
  use Web::UserAgent::Functions qw(http_post http_get);
  use JSON::PS;
  my $api_token = $ENV{API_TOKEN};
  my $host = 'localhost:5710';
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
            sk_context => 'sketch',
          };
      my $json = json_bytes2perl $res->content;
      $http->set_response_cookie (sk => $json->{sk}, expires => $json->{sk_expires}, path => q</>, httponly => 1, secure => 0)
          if $json->{set_sk};

      my (undef, $res) = http_post
          url => qq<http://$host/login>,
          header_fields => {Authorization => 'Bearer ' . $api_token},
          params => {
            sk => $json->{sk},
            sk_context => 'sketch',
            server => $http->query_params->{server},
            callback_url => $http->url->resolve_string ('/cb')->stringify,
          };
      my $json = json_bytes2perl $res->content;
      $http->set_status (302);
      $http->set_response_header (Location => $json->{authorization_url});
    } elsif ($path eq '/cb') {
      my (undef, $res) = http_post
          url => qq<http://$host/cb>,
          header_fields => {Authorization => 'Bearer ' . $api_token},
          params => {
            sk => $http->request_cookies->{sk},
            sk_context => 'sketch',
            oauth_token => $http->query_params->{oauth_token},
            oauth_verifier => $http->query_params->{oauth_verifier},
            code => $http->query_params->{code},
            state => $http->query_params->{state},
          };
      $http->set_status (302);
      $http->set_response_header (Location => '/info');
    } elsif ($path eq '/info') {
      my (undef, $res) = http_post
          url => qq<http://$host/info>,
          header_fields => {Authorization => 'Bearer ' . $api_token},
          params => {
            sk => $http->request_cookies->{sk},
            sk_context => 'sketch',
          };
      $http->send_response_body_as_ref (\($res->content));
    } elsif ($path eq '/repos') {
      my (undef, $res) = http_post
          url => qq<http://$host/token>,
          header_fields => {Authorization => 'Bearer ' . $api_token},
          params => {
            sk => $http->request_cookies->{sk},
            sk_context => 'sketch',
            server => 'github',
          };
      my $json = json_bytes2perl $res->content;
      my $token = $json->{access_token};
      (undef, $res) = http_get
          url => q<https://api.github.com/user/repos>,
          header_fields => {Authorization => 'token ' . $token},
          ;
      $http->set_response_header ('Content-Type' => 'text/plain');
      $http->send_response_body_as_ref (\($res->content));
    } elsif ($path eq '/athelete') {
      my (undef, $res) = http_post
          url => qq<http://$host/token>,
          header_fields => {Authorization => 'Bearer ' . $api_token},
          params => {
            sk => $http->request_cookies->{sk},
            sk_context => 'sketch',
            server => 'strava',
          };
      my $json = json_bytes2perl $res->content;
      my $token = $json->{access_token};
      (undef, $res) = http_get
          url => q<https://www.strava.com/api/v3/athlete>,
          header_fields => {Authorization => 'Bearer ' . $token},
          ;
      $http->set_response_header ('Content-Type' => 'text/plain');
      $http->send_response_body_as_ref (\($res->content));
    }
    $http->close_response_body;
    return $http->send_response;
  };
});
$plackup->start->then (sub {
  
});
$cv->recv;
