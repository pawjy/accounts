use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create_session (s1 => {})->then (sub {
    return $current->are_errors (
      [['token'], {
        server => 'oauth1server',
        sk => $current->o ('s1')->{sk},
      }],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {params => {sk => $current->o ('s1')->{sk}}, status => 400, name => 'no server'},
        {params => {sk => $current->o ('s1')->{sk}, server => 'hoge'}, status => 400, name => 'bad server'},
      ],
    );
  })->then (sub {
    return $current->post (['token'], {
      server => 'oauth1server',
      sk => $current->o ('s1')->{sk},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, undef;
    } $current->c;
  });
} n => 3, name => '/token has anon session';

Test {
  my $current = shift;
  return Promise->resolve->then (sub {
    return $current->post (['token'], {
      server => 'oauth1server',
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, undef;
    } $current->c;
  });
} n => 2, name => '/token has no session';

Test {
  my $current = shift;
  return $current->create_session (s1 => {})->then (sub {
    return $current->post (['token'], {
      server => 'oauth1server',
      sk => rand,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, undef;
    } $current->c;
  });
} n => 2, name => '/token has bad session';

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->post (['token'], {
      server => 'oauth1server',
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, $current->o ('a1')->{account_id};
    } $current->c;
  });
} n => 2, name => '/token has account_id no token';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $x_account_id = int rand 100000;
  return $current->create_session (s1 => {})->then (sub {
    return $current->post (['create'], {}, session => 's1');
  })->then (sub {
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    $account_id = $result->{json}->{account_id};
    return $current->post (['link'], {
      server => 'oauth1server',
      callback_url => $cb_url,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = Web::Transport::ConnectionClient->new_from_url ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_id => $x_account_id,
    }); # user accepted!
  })->then (sub {
    my $result = $_[0];
    return test {
      is $result->status, 302;
      my $location = $result->header ('Location');
      my ($base, $query) = split /\?/, $location, 2;
      is $base, $cb_url;
      return $current->post ("/cb?$query", {}, session => 's1');
    } $current->c;
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    return $current->post (['token'], {
      server => 'oauth1server',
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      ok $result->{json}->{access_token};
      is $result->{json}->{account_id}, $account_id;
    } $current->c;
    return $current->post (['token'], {
      server => 'oauth2server',
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, $account_id;
    } $current->c;
  });
} n => 8, name => '/token - oauth1';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $x_account_id = int rand 100000;
  return $current->create_session (s1 => {})->then (sub {
    return $current->post (['create'], {}, session => 's1');
  })->then (sub {
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    $account_id = $result->{json}->{account_id};
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = Web::Transport::ConnectionClient->new_from_url ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_id => $x_account_id,
    }); # user accepted!
  })->then (sub {
    my $result = $_[0];
    return test {
      is $result->status, 302;
      my $location = $result->header ('Location');
      my ($base, $query) = split /\?/, $location, 2;
      is $base, $cb_url;
      return $current->post ("/cb?$query", {}, session => 's1');
    } $current->c;
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    return $current->post (['token'], {
      server => 'oauth2server',
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      ok $result->{json}->{access_token};
      is $result->{json}->{account_id}, $account_id;
    } $current->c;
    return $current->post (['token'], {
      server => 'oauth1server',
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, $account_id;
    } $current->c;
  });
} n => 8, name => '/token - oauth2';

RUN;

=head1 LICENSE

Copyright 2015-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
