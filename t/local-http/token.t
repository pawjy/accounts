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
  my $link_id;
  my $token1;
  return $current->create_session (s1 => {})->then (sub {
    return $current->create_account (a2 => {});
  })->then (sub {
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
      ok $token1 = $result->{json}->{access_token};
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
    return $current->post (['token'], {
      server => 'oauth2server',
      account_link_id => 2452444444,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, $account_id;
    } $current->c, name => 'Bad |account_link_id|';
    return $current->post (['info'], {with_linked => 1}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    $link_id = [values %{$result->{json}->{links}}]->[0]->{account_link_id};
    return $current->post (['token'], {
      server => 'oauth2server',
      account_link_id => $link_id,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, $token1;
      is $result->{json}->{account_id}, $account_id;
    } $current->c, name => 'With explicit |account_link_id|';
    return $current->post (['token'], {
      server => 'oauth2server',
      account_id => $current->o ('a2')->{account_id},
      account_link_id => $link_id,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, $current->o ('a2')->{account_id};
    } $current->c, name => 'With bad account |account_link_id|';
  });
} n => 14, name => '/token - oauth2';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $name1 = rand;
  my $id1 = int rand 100000;
  my $name2 = rand;
  my $id2 = int rand 100000;
  my $link_id1;
  my $link_id2;
  my $token1;
  my $token2;
  return $current->create_session (1)->then (sub {
    return $current->post (['login'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = Web::Transport::ConnectionClient->new_from_url ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_id => $id1,
      account_name => $name1,
    }); # user accepted!
  })->then (sub {
    my $result = $_[0];
    return test {
      is $result->status, 302;
      my $location = $result->header ('Location');
      my ($base, $query) = split /\?/, $location, 2;
      is $base, $cb_url;
      return $current->post ("/cb?$query", {}, session => 1);
    } $current->c;
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
  })->then (sub {
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = Web::Transport::ConnectionClient->new_from_url ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_name => $name2,
      account_id => $id2,
    }); # user accepted!
  })->then (sub {
    my $result = $_[0];
    my $location = $result->header ('Location');
    my ($base, $query) = split /\?/, $location, 2;
    return $current->post ("/cb?$query", {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    return $current->post (['info'], {with_linked => ['id', 'name']}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      $account_id = $result->{json}->{account_id};
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is 0+@$ls, 2;
      my $link1 = [grep { $_->{name} eq $name1 } values %$links]->[0];
      my $link2 = [grep { $_->{name} eq $name2 } values %$links]->[0];
      $link_id1 = $link1->{account_link_id};
      $link_id2 = $link2->{account_link_id};
    } $current->c;
    return $current->post (['token'], {
      server => 'oauth2server',
      account_link_id => $link_id1,
    }, session => '1');
  })->then (sub {
    my $result = $_[0];
    test {
      ok $token1 = $result->{json}->{access_token};
      is $result->{json}->{account_id}, $account_id;
    } $current->c;
    return $current->post (['token'], {
      server => 'oauth2server',
      account_link_id => $link_id2,
    }, session => '1');
  })->then (sub {
    my $result = $_[0];
    test {
      ok $token2 = $result->{json}->{access_token};
      isnt $token2, $token1;
      is $result->{json}->{account_id}, $account_id;
    } $current->c;
    return $current->post (['token'], {
      server => 'oauth2server',
      account_link_id => undef,
    }, session => '1');
  })->then (sub {
    my $result = $_[0];
    test {
      ok $result->{json}->{access_token} eq $token1 ||
         $result->{json}->{access_token} eq $token2;
      is $result->{json}->{account_id}, $account_id;
    } $current->c;
  });
} n => 14, name => '/token different account links';

RUN;

=head1 LICENSE

Copyright 2015-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
