use strict;
use warnings;
use MIME::Base64;
use Web::UserAgent::Functions;
use JSON::PS;

my $token = decode_base64 shift;
my $host = 'localhost:5710';

my (undef, $res) = http_post
    url => qq<http://$host/ats/create>,
    header_fields => {Authorization => 'Bearer ' . $token},
    params => {
      app_name => 'test1',
      server => 'hatena',
      flow => 'login',
    };

my $json = json_bytes2perl $res->content;
my $atsl = $json->{atsl};

my $url = qq<http://$host/start?atsl=$atsl>;
warn $url;
