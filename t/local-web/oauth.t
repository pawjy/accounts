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
      url => qq<http://$host/start?app_data=ho%E3%81%82%00e&server=> . $server_type,
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
      return post ("$wd/session/$sid/execute", {
        script => q{ return document.body.textContent },
        args => [],
      });
    })->then (sub {
      my $value = $_[0]->{value};
      test {
        my $json = json_bytes2perl decode_base64 $value;
        is $json->{status}, 200, 'oauth login result';
        is $json->{app_data}, "ho\x{3042}\x00e";
      } $c;
    })->then (sub {
      return post ("$wd/session/$sid/url", {
        url => qq<http://$host/token?server=> . $server_type,
      });
    })->then (sub {
      return post ("$wd/session/$sid/execute", {
        script => q{ return document.body.textContent },
        args => [],
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->{value};
      test {
        if ($server_type =~ /oauth1/) {
          is ref $json->{access_token}, 'ARRAY';
          like $json->{access_token}->[0], qr{.+};
          like $json->{access_token}->[1], qr{.+};
        } else {
          is ref $json->{access_token}, '';
          like $json->{access_token}, qr{.+};
          ok 1;
        }
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
        is $json->{name}, $c->received_data->{oauth_server_account_name};
        ok $json->{account_id};
      } $c;
      return $json->{account_id};
    })->then (sub {
      my $aid = $_[0];
      return post ("$wd/session/$sid/url", {
        url => qq<http://$host/profiles?account_id=$aid>,
      })->then (sub {
        return post ("$wd/session/$sid/execute", {
          script => q{ return document.body.textContent },
          args => [],
        });
      })->then (sub {
        my $json = json_bytes2perl $_[0]->{value};
        test {
          ok $json->{accounts}->{$aid};
          is $json->{accounts}->{$aid}->{name}, $c->received_data->{oauth_server_account_name};
          is $json->{accounts}->{$aid}->{account_id}, $aid;
        } $c, name => '/profiles';
        return $aid;
      });
    });
  })->then (sub {
    my $account_id = $_[0];
    return post ("$wd/session", {
      desiredCapabilities => {
        browserName => 'firefox', # XXX
      },
    })->then (sub {
      my $json = $_[0];
      my $sid = $json->{sessionId};
      return post ("$wd/session/$sid/url", {
        url => qq<http://$host/start?server=> . $server_type,
      })->then (sub {
        return post ("$wd/session/$sid/execute", {
          script => q{
            document.querySelector ('form [type=submit]').click ();
          },
          args => [],
        });
      })->then (sub {
        return post ("$wd/session/$sid/url", {
          url => qq<http://$host/info>,
        });
      })->then (sub {
        return post ("$wd/session/$sid/execute", {
          script => q{ return document.body.textContent },
          args => [],
        });
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->{value};
      test {
        is $json->{name}, $c->received_data->{oauth_server_account_name};
        is $json->{account_id}, $account_id;
      } $c, name => 'second login';
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 13, name => ['/oauth', $server_type], timeout => 60;

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
      url => qq<http://$host/start?bad_state=1&server=> . $server_type,
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
      return post ("$wd/session/$sid/execute", {
        script => q{ return document.body.textContent },
        args => [],
      });
    })->then (sub {
      my $value = $_[0]->{value};
      test {
        is $value, 400;
      } $c;
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 2, name => ['/oauth bad state', $server_type], timeout => 60;

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
      url => qq<http://$host/start?bad_code=1&server=> . $server_type,
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
      return post ("$wd/session/$sid/execute", {
        script => q{ return document.body.textContent },
        args => [],
      });
    })->then (sub {
      my $value = $_[0]->{value};
      test {
        is $value, 400;
      } $c;
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 2, name => ['/oauth bad code', $server_type], timeout => 60;

}

run_tests;
stop_web_server_and_driver;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
