use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->are_errors (
    [['session', 'get'], {sk_context => rand}],
    [
      {method => 'GET', status => 405},
      {bearer => undef, status => 401},
      {params => {}, status => 400, reason => 'No |account_id|'},
      {params => {use_sk => 1, account_id => 4}, status => 400},
    ],
  )->then (sub {
    return $current->post (['session', 'get'], {
      account_id => 1344,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
    return $current->post (['session', 'get'], {
      account_id => 0,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+(grep { $_->{account_id} } @{$result->{json}->{items}}), 0;
    } $current->c;
  });
} n => 3, name => '/session/get';

Test {
  my $current = shift;
  $current->generate_id (i1 => {});
  return $current->create (
    [s1 => session => {}],
    [s2 => session => {}],
    [s3 => session => {}],
    [s4 => session => {}],
    [s5 => session => {}],
  )->then (sub {
    my $cb_url = 'http://haoa/' . rand;
    $current->generate_id (xa1 => {});
    return promised_for {
      my $session = shift;
      return $current->post (['login'], {
        server => 'oauth2server',
        callback_url => $cb_url,
      }, session => $session)->then (sub {
        my $result = $_[0];
        my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
        my $con = $current->client_for ($url);
        return $con->request (url => $url, method => 'POST', params => {
          account_id => $current->o ('xa1'),
        });
      })->then (sub {
        my $result = $_[0];
        my $location = $result->header ('Location');
        my ($base, $query) = split /\?/, $location, 2;
        $current->o ($session)->{ua} = $current->generate_key (rand, {});
        return $current->post ("/cb?$query", {
          source_ua => $current->o ($session)->{ua},
        }, session => $session);
      });
    } ['s1', 's2', 's3', 's4', 's5'];
  })->then (sub {
    return $current->post (['info'], {
    }, session => "s1");
  })->then (sub {
    $current->set_o (a1 => $_[0]->{json});
    return $current->pages_ok ([['session', 'get'], {
      account_id => $current->o ('a1')->{account_id},
    }] => ['s1', 's2', 's3', 's4', 's5'], 'ua', undef, items => sub {
      for (@{$_[0]}) {
        $_->{ua} = $_->{log_data}->{ua};
      }
      return $_[0];
    });
  });
} n => 1, name => 'paging';

Test {
  my $current = shift;
  $current->generate_id (i1 => {});
  return $current->create (
    [s1 => session => {sk_context => $current->generate_key (k1 => {})}],
    [s2 => session => {sk_context => $current->o ('k1')}],
    [s3 => session => {sk_context => $current->generate_key (k3 => {})}],
    [s4 => session => {sk_context => $current->o ('k3')}],
    [s5 => session => {sk_context => $current->generate_key (k5 => {})}],
  )->then (sub {
    my $cb_url = 'http://haoa/' . rand;
    $current->generate_id (xa1 => {});
    return promised_for {
      my $session = shift;
      return $current->post (['login'], {
        server => 'oauth2server',
        callback_url => $cb_url,
      }, session => $session)->then (sub {
        my $result = $_[0];
        my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
        my $con = $current->client_for ($url);
        return $con->request (url => $url, method => 'POST', params => {
          account_id => $current->o ('xa1'),
        });
      })->then (sub {
        my $result = $_[0];
        my $location = $result->header ('Location');
        my ($base, $query) = split /\?/, $location, 2;
        $current->o ($session)->{ua} = $current->generate_key (rand, {});
        return $current->post ("/cb?$query", {
          source_ua => $current->o ($session)->{ua},
        }, session => $session);
      });
    } ['s1', 's2', 's3', 's4', 's5'];
  })->then (sub {
    return $current->post (['info'], {
    }, session => "s1");
  })->then (sub {
    $current->set_o (a1 => $_[0]->{json});
    return $current->post (['session', 'get'], {
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 5;
    } $current->c;
    return $current->post (['session', 'get'], {
      account_id => $current->o ('a1')->{account_id},
      session_sk_context => $current->o ('k1'),
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 2;
      is $result->{json}->{items}->[0]->{sk_context}, $current->o ('k1');
      is $result->{json}->{items}->[0]->{log_data}->{ua}, $current->o ('s2')->{ua};
      is $result->{json}->{items}->[1]->{sk_context}, $current->o ('k1');
      is $result->{json}->{items}->[1]->{log_data}->{ua}, $current->o ('s1')->{ua};
    } $current->c;
    return $current->post (['session', 'get'], {
      account_id => $current->o ('a1')->{account_id},
      session_sk_context => [$current->o ('k3'), $current->o ('k5'), rand],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 3;
      is $result->{json}->{items}->[0]->{sk_context}, $current->o ('k5');
      is $result->{json}->{items}->[0]->{log_data}->{ua}, $current->o ('s5')->{ua};
      is $result->{json}->{items}->[1]->{sk_context}, $current->o ('k3');
      is $result->{json}->{items}->[1]->{log_data}->{ua}, $current->o ('s4')->{ua};
      is $result->{json}->{items}->[2]->{sk_context}, $current->o ('k3');
      is $result->{json}->{items}->[2]->{log_data}->{ua}, $current->o ('s3')->{ua};
    } $current->c;
    return $current->post (['session', 'get'], {
      account_id => $current->o ('a1')->{account_id},
      session_sk_context => [rand],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
  });
} n => 14, name => 'session_sk_context';

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {
      source_ua => $current->generate_key ('k1', {}),
      sk_context => $current->generate_key (k2 => {}),
    }],
  )->then (sub {
    return $current->post (['session', 'get'], {
      use_sk => 1,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      my $item = $result->{json}->{items}->[0];
      is $item->{sk_context}, $current->o ('s1')->{sk_context};
      is $item->{sk}, undef;
      ok $item->{session_id};
      is $item->{log_data}->{ua}, $current->o ('k1');
    } $current->c;
    return $current->post (['session', 'get'], {
      use_sk => 1,
      session_sk_context => rand,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
    return $current->post (['session', 'get'], {
      use_sk => 1,
      session_sk_context => [rand, $current->o ('k2')],
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      my $item = $result->{json}->{items}->[0];
      is $item->{sk_context}, $current->o ('s1')->{sk_context};
      is $item->{sk}, undef;
      ok $item->{session_id};
      is $item->{log_data}->{ua}, $current->o ('k1');
    } $current->c;
  });
} n => 11, name => 'use_sk no account';

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {
      sk_context => $current->generate_key (k2 => {}),
    }],
    [s2 => session => {
      sk_context => $current->o ('k2'),
    }],
    [s3 => session => {
      sk_context => $current->generate_key (k3 => {}),
    }],
  )->then (sub {
    $current->generate_id (xa1 => {});
    my $cb_url = 'http://haoa/' . rand;
    return promised_for {
      my $session = shift;
      return $current->post (['login'], {
        server => 'oauth2server',
        callback_url => $cb_url,
      }, session => $session)->then (sub {
        my $result = $_[0];
        my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
        my $con = $current->client_for ($url);
        return $con->request (url => $url, method => 'POST', params => {
          account_id => $current->o ('xa1'),
        });
      })->then (sub {
        my $result = $_[0];
        my $location = $result->header ('Location');
        my ($base, $query) = split /\?/, $location, 2;
        $current->o ($session)->{ua} = $current->generate_key (rand, {});
        return $current->post ("/cb?$query", {
          source_ua => $current->o ($session)->{ua},
        }, session => $session);
      });
    } ['s1'];
  })->then (sub {
    return $current->post (['info'], {
    }, session => "s1");
  })->then (sub {
    $current->set_o (a1 => $_[0]->{json});
    return $current->post (['session', 'get'], {
      use_sk => 1,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      my $item = $result->{json}->{items}->[0];
      is $item->{sk_context}, $current->o ('s1')->{sk_context};
      is $item->{sk}, undef;
      ok $item->{session_id};
      is $item->{log_data}->{ua}, $current->o ('s1')->{ua};
    } $current->c;
    return $current->post (['session', 'get'], {
      use_sk => 1,
      session_sk_context => rand,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
    return $current->post (['session', 'get'], {
      use_sk => 1,
      session_sk_context => [rand, $current->o ('k2')],
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      my $item = $result->{json}->{items}->[0];
      is $item->{sk_context}, $current->o ('s1')->{sk_context};
      is $item->{sk}, undef;
      ok $item->{session_id};
      is $item->{log_data}->{ua}, $current->o ('s1')->{ua};
    } $current->c;
    my $cb_url = 'http://haoa/' . rand;
    return promised_for {
      my $session = shift;
      return $current->post (['login'], {
        server => 'oauth2server',
        callback_url => $cb_url,
      }, session => $session)->then (sub {
        my $result = $_[0];
        my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
        my $con = $current->client_for ($url);
        return $con->request (url => $url, method => 'POST', params => {
          account_id => $current->o ('xa1'),
        });
      })->then (sub {
        my $result = $_[0];
        my $location = $result->header ('Location');
        my ($base, $query) = split /\?/, $location, 2;
        $current->o ($session)->{ua} = $current->generate_key (rand, {});
        return $current->post ("/cb?$query", {
          source_ua => $current->o ($session)->{ua},
        }, session => $session);
      });
    } ['s2'];
  })->then (sub {
    return $current->post (['session', 'get'], {
      use_sk => 1,
      session_sk_context => [rand, $current->o ('k2')],
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 2;
      my $item = $result->{json}->{items}->[0];
      is $item->{sk_context}, $current->o ('s2')->{sk_context};
      is $item->{sk}, undef;
      ok $item->{session_id};
      is $item->{log_data}->{ua}, $current->o ('s2')->{ua};
    } $current->c;
    my $cb_url = 'http://haoa/' . rand;
    return promised_for {
      my $session = shift;
      return $current->post (['login'], {
        server => 'oauth2server',
        callback_url => $cb_url,
      }, session => $session)->then (sub {
        my $result = $_[0];
        my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
        my $con = $current->client_for ($url);
        return $con->request (url => $url, method => 'POST', params => {
          account_id => $current->o ('xa1'),
        });
      })->then (sub {
        my $result = $_[0];
        my $location = $result->header ('Location');
        my ($base, $query) = split /\?/, $location, 2;
        $current->o ($session)->{ua} = $current->generate_key (rand, {});
        return $current->post ("/cb?$query", {
          source_ua => $current->o ($session)->{ua},
        }, session => $session);
      });
    } ['s3'];
  })->then (sub {
    return $current->post (['session', 'get'], {
      use_sk => 1,
      session_sk_context => [rand, $current->o ('k2')],
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 2;
    } $current->c;
    return $current->post (['session', 'get'], {
      use_sk => 1,
      session_sk_context => $current->o ('k3'),
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      my $item = $result->{json}->{items}->[0];
      is $item->{sk_context}, $current->o ('s3')->{sk_context};
      is $item->{sk}, undef;
      ok $item->{session_id};
      is $item->{log_data}->{ua}, $current->o ('s3')->{ua};
    } $current->c;
  });
} n => 22, name => 'use_sk has account';

## See also: t/http/create.t

RUN;

=head1 LICENSE

Copyright 2023 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
