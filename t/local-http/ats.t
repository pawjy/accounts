use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Test::More;
use Test::X1;
use Promise;
use Web::UserAgent::Functions qw(http_post);
use JSON::PS;

my $wait = web_server;

sub create ($$) {
  my ($c, $params) = @_;
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    my $host = $c->received_data->{host};
    http_post
        url => qq<http://$host/ats/create>,
        params => $params,
        header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'ats.bearer'}},
        max_redirect => 0,
        anyevent => 1,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } else {
            $ng->($res->code);
          }
        };
  });
} # create

test {
  my $c = shift;
  create ($c, {
    app_name => 'app1',
    callback_url => q<http://hoge/>,
  })->then (sub {
    my $json = $_[0];
    test {
      like $json->{atsk}, qr{\A\w+\z};
      like $json->{state}, qr{\A\w+\z};
      done $c;
      undef $c;
    } $c;
  });
} wait => $wait, n => 2, name => '/ats/create';

test {
  my $c = shift;
  create ($c, {
    app_name => 'app1',
  })->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 400;
      done $c;
      undef $c;
    } $c;
  });
} wait => $wait, n => 1, name => '/ats/create no callback_url';

test {
  my $c = shift;
  create ($c, {
    callback_url => 'app1',
  })->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 400;
      done $c;
      undef $c;
    } $c;
  });
} wait => $wait, n => 1, name => '/ats/create no app_name';

test {
  my $c = $_[0];
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    my $host = $c->received_data->{host};
    http_post
        url => qq<http://$host/ats/create>,
        params => {},
        max_redirect => 0,
        anyevent => 1,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } else {
            test {
              like $res->header ('WWW-Authenticate'), qr{^Bearer realm="", error="invalid_token"$};
            } $c;
            $ng->($res->code);
          }
        };
  })->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 401;
      done $c;
      undef $c;
    } $c;
  });
} wait => $wait, n => 2, name => '/ats/create no auth';

test {
  my $c = $_[0];
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    my $host = $c->received_data->{host};
    http_post
        url => qq<http://$host/ats/create>,
        header_fields => {Authorization => 'Bearer '},
        params => {},
        max_redirect => 0,
        anyevent => 1,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } else {
            test {
              like $res->header ('WWW-Authenticate'), qr{^Bearer realm="", error="invalid_token"$};
            } $c;
            $ng->($res->code);
          }
        };
  })->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 401;
      done $c;
      undef $c;
    } $c;
  });
} wait => $wait, n => 2, name => '/ats/create no auth';

test {
  my $c = $_[0];
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    my $host = $c->received_data->{host};
    http_post
        url => qq<http://$host/ats/create>,
        header_fields => {Authorization => 'Bearer hage'},
        params => {},
        max_redirect => 0,
        anyevent => 1,
        cb => sub {
          my $res = $_[1];
          if ($res->code == 200) {
            $ok->(json_bytes2perl $res->content);
          } else {
            test {
              like $res->header ('WWW-Authenticate'), qr{^Bearer realm="", error="invalid_token"$};
            } $c;
            $ng->($res->code);
          }
        };
  })->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 401;
      done $c;
      undef $c;
    } $c;
  });
} wait => $wait, n => 2, name => '/ats/create bad auth';

test {
  my $c = shift;
  create ($c, {
    callback_url => 'app1',
    app_name => 'ab cd',
  })->then (sub {
    my $json = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      my $host = $c->received_data->{host};
      http_post
          url => qq<http://$host/ats/get>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'ats.bearer'}},
          params => {
            app_name => 'ab cd',
            atsk => $json->{atsk},
            state => $json->{state},
          },
          anyevent => 1,
          cb => sub {
            my $res = $_[1];
            if ($res->code == 200) {
              $ok->(json_bytes2perl $res->content);
            } else {
              $ng->($res->code);
            }
          };
    })->then (sub {
      my $json2 = $_[0];
      test {
        is $json2->{callback_url}, 'app1';
      } $c;
      return Promise->new (sub {
        my ($ok, $ng) = @_;
        my $host = $c->received_data->{host};
        http_post
            url => qq<http://$host/ats/get>,
            header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'ats.bearer'}},
            params => {
              app_name => 'ab cd',
              atsk => $json->{atsk},
              state => $json->{state},
            },
            anyevent => 1,
            cb => sub {
              my $res = $_[1];
              if ($res->code == 200) {
                $ok->(json_bytes2perl $res->content);
              } else {
                $ng->($res->code);
              }
            };
      })->then (sub { test { ok 0 } $c }, sub {
        my $status = $_[0];
        test {
          is $status, 404;
        } $c;
      });
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 2, name => '/ats/get';

test {
  my $c = shift;
  create ($c, {
    callback_url => 'app1',
    app_name => 'ab cd',
  })->then (sub {
    my $json = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      my $host = $c->received_data->{host};
      http_post
          url => qq<http://$host/ats/get>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'ats.bearer'}},
          params => {
            app_name => 'ab cd',
            atsk => $json->{atsk},
            state => 'foo',
          },
          anyevent => 1,
          cb => sub {
            my $res = $_[1];
            if ($res->code == 200) {
              $ok->(json_bytes2perl $res->content);
            } else {
              $ng->($res->code);
            }
          };
    })->then (sub { test { ok 0 } $c }, sub {
      my $status = $_[0];
      test {
        is $status, 403;
      } $c;
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/ats/get bad state';

test {
  my $c = shift;
  create ($c, {
    callback_url => 'app1',
    app_name => 'ab cd',
  })->then (sub {
    my $json = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      my $host = $c->received_data->{host};
      http_post
          url => qq<http://$host/ats/get>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'ats.bearer'}},
          params => {
            app_name => 'ab cd',
            atsk => 'hoge',
            state => $json->{state},
          },
          anyevent => 1,
          cb => sub {
            my $res = $_[1];
            if ($res->code == 200) {
              $ok->(json_bytes2perl $res->content);
            } else {
              $ng->($res->code);
            }
          };
    })->then (sub { test { ok 0 } $c }, sub {
      my $status = $_[0];
      test {
        is $status, 404;
      } $c;
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/ats/get bad atsk';

test {
  my $c = shift;
  create ($c, {
    callback_url => 'app1',
    app_name => 'ab cd',
  })->then (sub {
    my $json = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      my $host = $c->received_data->{host};
      http_post
          url => qq<http://$host/ats/get>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'ats.bearer'}},
          params => {
            app_name => 'ab cd ',
            atsk => $json->{atsk},
            state => $json->{state},
          },
          anyevent => 1,
          cb => sub {
            my $res = $_[1];
            if ($res->code == 200) {
              $ok->(json_bytes2perl $res->content);
            } else {
              $ng->($res->code);
            }
          };
    })->then (sub { test { ok 0 } $c }, sub {
      my $status = $_[0];
      test {
        is $status, 404;
      } $c;
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/ats/get bad app name';

test {
  my $c = shift;
  create ($c, {
    callback_url => 'app1',
    app_name => 'ab cd',
  })->then (sub {
    my $json = $_[0];
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      my $host = $c->received_data->{host};
      http_post
          url => qq<http://$host/ats/get>,
          header_fields => {Authorization => 'Bearer ' . $c->received_data->{keys}->{'ats.bearer'} . ' aa'},
          params => {
            app_name => 'ab cd',
            atsk => $json->{atsk},
            state => $json->{state},
          },
          anyevent => 1,
          cb => sub {
            my $res = $_[1];
            if ($res->code == 200) {
              $ok->(json_bytes2perl $res->content);
            } else {
              $ng->($res->code);
            }
          };
    })->then (sub { test { ok 0 } $c }, sub {
      my $status = $_[0];
      test {
        is $status, 401;
      } $c;
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/ats/get bad bearer';

run_tests;
stop_web_server;
