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
      url => qq<http://$host/start?app_data=ho%E3%81%82%00e&server=ssh>,
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{
          return document.body.textContent;
        },
        args => [],
      });
    })->then (sub {
      my $value = $_[0]->{value};
      my $json = json_chars2perl $value;
      test {
        is $json->{reason}, 'Not a loginable |server|';
      } $c;
      return get ("$wd/session/$sid/url")->then (sub {
        my $value = $_[0]->{value};
        test {
          like $value, qr{^http://$host/start\?};
        } $c;
      });
    })->then (sub {
      return post ("$wd/session/$sid/url", {
        url => qq<http://$host/token?server=ssh>,
      });
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{ return document.body.textContent },
        args => [],
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->{value};
      test {
        ok not defined $json->{access_token};
      } $c, name => '/token';
      return $json->{account_id};
    })->then (sub {
      return post ("$wd/session/$sid/url", {
        url => qq<http://$host/info>,
      });
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{ return document.body.textContent },
        args => [],
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->{value};
      test {
        is $json->{name}, undef;
        is $json->{account_id}, undef;
      } $c;
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 5, name => ['/oauth', 'ssh'], timeout => 120*5;

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
      url => qq<http://$host/start?app_data=ho%E3%81%82%00e&server=hogefugaa13r5>,
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{
          return document.body.textContent;
        },
        args => [],
      });
    })->then (sub {
      my $value = $_[0]->{value};
      my $json = json_chars2perl $value;
      test {
        is $json->{reason}, 'Bad |server|';
      } $c;
      return get ("$wd/session/$sid/url")->then (sub {
        my $value = $_[0]->{value};
        test {
          like $value, qr{^http://$host/start\?};
        } $c;
      });
    })->then (sub {
      return post ("$wd/session/$sid/url", {
        url => qq<http://$host/token?server=hogefugaa13r5>,
      });
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{ return document.body.textContent },
        args => [],
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->{value};
      test {
        ok not defined $json->{access_token};
      } $c, name => '/token';
      return $json->{account_id};
    })->then (sub {
      return post ("$wd/session/$sid/url", {
        url => qq<http://$host/info>,
      });
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{ return document.body.textContent },
        args => [],
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->{value};
      test {
        is $json->{name}, undef;
        is $json->{account_id}, undef;
      } $c;
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 5, name => ['/oauth', 'unknown server'], timeout => 120*5;

run_tests;
stop_web_server_and_driver;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
