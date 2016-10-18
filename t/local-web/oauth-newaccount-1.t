use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Test::More;
use Test::X1;
use Web::UserAgent::Functions qw(http_post_data http_get);
use JSON::PS;
use MIME::Base64;
use Promise;

my $wait = web_server_and_driver;

sub post ($$) {
  my ($url, $json) = @_;
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post_data
        url => $url,
        content => perl2json_bytes ($json || {}),
        timeout => 100*5,
        anyevent => 1,
        cb => sub {
          my (undef, $res) = @_;
          if ($res->code == 200) {
            my $json = json_bytes2perl $res->content;
            if (defined $json and ref $json) {
              $ok->($json);
            } else {
              $ng->($res->code . "\n" . $res->content);
            }
          } elsif ($res->is_success) {
            $ok->({status => $res->code});
          } else {
            $ng->($res->code . "\n" . $res->content);
          }
        };
  });
} # post

sub get ($) {
  my ($url) = @_;
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_get
        url => $url,
        timeout => 100*5,
        anyevent => 1,
        cb => sub {
          my (undef, $res) = @_;
          if ($res->code == 200) {
            my $json = json_bytes2perl $res->content;
            if (defined $json and ref $json) {
              $ok->($json);
            } else {
              $ng->($res->code . "\n" . $res->content);
            }
          } elsif ($res->is_success) {
            $ok->({status => $res->code});
          } else {
            $ng->($res->code . "\n" . $res->content);
          }
        };
  });
} # get

for my $server_type (qw(oauth1server oauth2server)) {

test {
  my $c = shift;
  my $host = $c->received_data->{host_for_browser};
  my $wd = $c->received_data->{wd_url};
  return post ("$wd/session", {
    desiredCapabilities => {
      browserName => 'firefox', # XXX
    },
  })->then (sub {
    my $json = $_[0];
    my $sid = $json->{sessionId};
    return post ("$wd/session/$sid/url", {
      url => qq<http://$host/start?copied_data_field=id:abcid&copied_data_field=name:fuga&server=> . $server_type,
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{
          document.querySelector ('form [type=submit]').click ();
        },
        args => [],
      });
    })->then (sub {
      return get ("$wd/session/$sid/url")->then (sub {
        my $value = $_[0]->{value};
        test {
          like $value, qr{^http://$host/cb\?};
        } $c;
      });
    })->then (sub {
      return post ("$wd/session/$sid/url", {
        url => qq<http://$host/info?with_data=abcid&with_data=fuga>,
      });
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{ return document.body.textContent },
        args => [],
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->{value};
      test {
        is $json->{data}->{abcid}, undef;
        is $json->{data}->{fuga}, undef;
      } $c, name => '/info';
      return $json->{account_id};
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 3, name => ['/oauth copied_data_field', $server_type], timeout => 120*5;

}

run_tests;
stop_web_server_and_driver;

=head1 LICENSE

Copyright 2015-2016 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
