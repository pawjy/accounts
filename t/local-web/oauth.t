use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Test::More;
use Test::X1;
use Web::UserAgent::Functions qw(http_post_data http_get);
use JSON::PS;
use Promise;

my $wait = web_server_and_driver;

sub post ($$) {
  my ($url, $json) = @_;
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    http_post_data
        url => $url,
        content => perl2json_bytes ($json || {}),
        timeout => 100,
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
        timeout => 100,
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
      url => qq<http://$host/oauth>,
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{ return document.cookie },
        args => [],
      });
    })->then (sub {
      my $value = $_[0]->{value};
      test {
        unlike $value, qr{\bsk=}, 'httponly';
      } $c;
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/oauth sk';

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
      url => qq<http://$host/oauth?server=hatena>,
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{ return document.forms[0].submit () },
        args => [],
      });
    })->then (sub {
      return get ("$wd/session/$sid/url")->then (sub {
        my $value = $_[0]->{value};
        test {
          like $value, qr{^https://www.hatena.ne.jp/oauth/};
        } $c;
      });
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{
          document.querySelector ('form input[name=name]').value = arguments[0];
          document.querySelector ('form input[name=password]').value = arguments[1];
          document.querySelector ('form [type=submit]').click ();
        },
        args => [$c->received_data->{keys}->{'test.hatena_id'},
                 $c->received_data->{keys}->{'test.hatena_password'}],
      });
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{
          document.querySelector ('form [type=submit]').click ();
        },
        args => [$c->received_data->{keys}->{'test.hatena_id'},
                 $c->received_data->{keys}->{'test.hatena_password'}],
      });
    })->then (sub {
      return get ("$wd/session/$sid/url")->then (sub {
        my $value = $_[0]->{value};
        test {
          like $value, qr{^http://$host/};
        } $c;
      });
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 2, name => '/oauth hatena';

run_tests;
stop_web_server_and_driver;
