use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->are_errors (
    [['session', 'delete'], {sk_context => rand}],
    [
      {method => 'GET', status => 405},
      {bearer => undef, status => 401},
      {params => {}, status => 400, reason => 'No |session_id|'},
      {params => {sk_context => rand}, status => 400,
       reason => 'No |session_id|'},
      {params => {sk_context => rand, sk => rand}, status => 400,
       reason => 'No |session_id|'},
    ],
  )->then (sub {
    return $current->post (['session', 'delete'], {
      session_id => 1344,
    }); # nop
  })->then (sub {
    return $current->post (['session', 'delete'], {
      use_sk => 1,
    }); # nop
  })->then (sub {
    return $current->post (['session', 'delete'], {
      use_sk => 1,
      sk => rand,
    }); # nop
  });
} n => 1, name => 'nop';

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {session_id => 1}],
  )->then (sub {
    return $current->post (['session', 'delete'], {
      session_id => $current->o ('s1')->{session_id},
    });
  })->then (sub {
    return $current->post (['session', 'get'], {
      use_sk => 1,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
    return $current->post (['session', 'delete'], {
      session_id => $current->o ('s1')->{session_id},
    }); # nop
  });
} n => 1, name => 'session_id';

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {}],
  )->then (sub {
    return $current->post (['session', 'delete'], {
      use_sk => 1,
    }, session => 's1');
  })->then (sub {
    return $current->post (['session', 'get'], {
      use_sk => 1,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
    return $current->post (['session', 'delete'], {
      use_sk => 1,
    }, session => 's1'); # nop
  });
} n => 1, name => 'use_sk';

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {session_id => 1}],
    [s2 => session => {session_id => 1}],
  )->then (sub {
    return $current->post (['session', 'delete'], {
      use_sk => 1,
      session_id => rand,
    }, session => 's1');
  })->then (sub {
    return $current->post (['session', 'delete'], {
      use_sk => 1,
      session_sk_context => rand,
    }, session => 's1');
  })->then (sub {
    return $current->post (['session', 'delete'], {
      use_sk => 1,
      session_id => $current->o ('s1')->{session_id}, # session mismatch
    }, session => 's2');
  })->then (sub {
    return $current->post (['session', 'delete'], {
      use_sk => 1,
      session_id => $current->o ('s1')->{session_id}, # session mismatch
    }, session => undef);
  })->then (sub {
    return $current->post (['session', 'get'], {
      use_sk => 1,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
    } $current->c;
    return $current->post (['session', 'delete'], {
      use_sk => 1,
      session_id => $current->o ('s1')->{session_id},
    }, session => 's1');
  })->then (sub {
    return $current->post (['session', 'get'], {
      use_sk => 1,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
    return $current->post (['session', 'delete'], {
      use_sk => 1,
      session_id => $current->o ('s1')->{session_id},
    }, session => 's1'); # nop
  });
} n => 2, name => 'use_sk and session_id';

Test {
  my $current = shift;
  $current->generate_id (i1 => {});
  return $current->create (
    [s1 => session => {sk_context => $current->generate_key (k1 => {}),
                       session_id => 1}],
    [s2 => session => {sk_context => $current->generate_key (k2 => {}),
                       session_id => 1}],
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
    } ['s1', 's2'];
  })->then (sub {
    return $current->post (['session', 'get'], {
      use_sk => 1,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 2;
    } $current->c;
    return $current->post (['session', 'delete'], {
      use_sk => 1,
      session_id => $current->o ('s2')->{session_id},
      session_sk_context => $current->o ('s2')->{sk_context},
    }, session => 's1');
  })->then (sub {
    return $current->post (['session', 'get'], {
      use_sk => 1,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
    } $current->c;
    return $current->post (['session', 'get'], {
      use_sk => 1,
    }, session => 's2');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
  });
} n => 3, name => 'use_sk and session_id session_sk_context';

RUN;

=head1 LICENSE

Copyright 2023 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
