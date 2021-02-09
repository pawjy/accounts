use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $x_account_id = int rand 100000;
  my $x_account_id2 = int rand 100000;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {}, session => 1);
  })->then (sub {
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    $account_id = $result->{json}->{account_id};
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
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
      return $current->post ("/cb?$query", {}, session => 1);
    } $current->c;
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is 0+@$ls, 1;
    } $current->c;
  })->then (sub {
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_id => $x_account_id2,
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
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $links = $result->{json}->{links};
    my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
    test {
      is $result->{status}, 200;
      is 0+@$ls, 2;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_id => $account_id,
      account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id2 } @$ls],
      #server => 'oauth2server',
    })->then (sub { test { ok 0 } $current->c }, sub {
      my $result = $_[0];
      test {
        is $result->{status}, 400;
      } $current->c;
      return $current->post (['info'], {with_linked => 'id'}, session => 1);
    })->then (sub {
      my $result = $_[0];
      my $links = $result->{json}->{links};
      my $ls2 = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      test {
        is $result->{status}, 200;
        is 0+@$ls2, 2;
      } $current->c, name => 'missing |server|';
      return $current->post (['link', 'delete'], {
        account_id => $account_id,
        account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id2 } @$ls],
        server => 'oauth2server',
      });
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{status}, 200;
      } $current->c;
      return $current->post (['info'], {with_linked => 'id'}, session => 1);
    })->then (sub {
      my $result = $_[0];
      my $links = $result->{json}->{links};
      my $ls2 = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      test {
        is $result->{status}, 200;
        is 0+@$ls2, 1;
        is $ls2->[0]->{id}, $x_account_id;
      } $current->c;
      return $current->post (['link', 'delete'], {
        account_id => $account_id . '1',
        account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id } @$ls],
        server => 'oauth2server',
      });
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{status}, 200;
      } $current->c;
      return $current->post (['info'], {with_linked => 'id'}, session => 1);
    })->then (sub {
      my $result = $_[0];
      my $links = $result->{json}->{links};
      my $ls2 = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      test {
        is $result->{status}, 200;
        is 0+@$ls2, 1;
        is $ls2->[0]->{id}, $x_account_id;
      } $current->c, name => 'wrong account id cant remove account link';
    });
  });
} n => 20, name => '/link/delete with account_id';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $x_account_id = int rand 100000;
  my $x_account_id2 = int rand 100000;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {}, session => 1);
  })->then (sub {
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    $account_id = $result->{json}->{account_id};
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
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
      return $current->post ("/cb?$query", {}, session => 1);
    } $current->c;
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is 0+@$ls, 1;
    } $current->c;
  })->then (sub {
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_id => $x_account_id2,
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
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $links = $result->{json}->{links};
    my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
    test {
      is $result->{status}, 200;
      is 0+@$ls, 2;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id2 } @$ls],
      #server => 'oauth2server',
    }, session => 1)->then (sub { test { ok 0 } $current->c }, sub {
      my $result = $_[0];
      test {
        is $result->{status}, 400;
      } $current->c;
      return $current->post (['info'], {with_linked => 'id'}, session => 1);
    })->then (sub {
      my $result = $_[0];
      my $links = $result->{json}->{links};
      my $ls2 = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      test {
        is $result->{status}, 200;
        is 0+@$ls2, 2;
      } $current->c, name => 'missing |server|';
      return $current->post (['link', 'delete'], {
        account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id2 } @$ls],
        server => 'oauth2server',
      }, session => 1);
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{status}, 200;
      } $current->c;
      return $current->post (['info'], {with_linked => 'id'}, session => 1);
    })->then (sub {
      my $result = $_[0];
      my $links = $result->{json}->{links};
      my $ls2 = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      test {
        is $result->{status}, 200;
        is 0+@$ls2, 1;
        is $ls2->[0]->{id}, $x_account_id;
      } $current->c;
      return $current->post (['link', 'delete'], {
        account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id } @$ls],
        server => 'oauth1server',
      }, session => 1);
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{status}, 200;
      } $current->c;
      return $current->post (['info'], {with_linked => 'id'}, session => 1);
    })->then (sub {
      my $result = $_[0];
      my $links = $result->{json}->{links};
      my $ls2 = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      test {
        is $result->{status}, 200;
        is 0+@$ls2, 1;
        is $ls2->[0]->{id}, $x_account_id;
      } $current->c, name => 'wrong server cant remove account link';
    });
  });
} n => 20, name => '/link/delete with session';

Test {
  my $current = shift;
  return $current->create (
    [a1 => account => {}],
  )->then (sub {
    return $current->post (['link', 'add'], {
      server => 'linktest1',
      linked_key => $current->generate_key ('k1' => {}),
      linked_id => $current->generate_id (i1 => {}),
    }, account => 'a1');
  })->then (sub {
    return $current->post (['link', 'add'], {
      server => 'linktest1',
      linked_key => $current->generate_key ('k2' => {}),
      linked_id => $current->generate_id (i2 => {}),
    }, account => 'a1');
  })->then (sub {
    return $current->post (['link', 'add'], {
      server => 'linktest2',
      linked_key => $current->generate_key ('k3' => {}),
      linked_id => $current->generate_id (i3 => {}),
    }, account => 'a1');
  })->then (sub {
    return $current->are_errors (
      [['link', 'delete'], {
        server => 'linktest2',
        sk => $current->o ('a1')->{account}->{sk},
        #sk_context is implied
        all => 1,
      }],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {params => {sk => $current->o ('a1')->{session}->{sk},
                    sk_context => undef,
                    server => 'linktest2',
                    all => 1}, status => 400,
         name => 'no sk_context'},
        {params => {sk => $current->o ('a1')->{session}->{sk},
                    sk_context => rand,
                    server => 'linktest2',
                    all => 1}, status => 400,
         name => 'bad sk_context'},
        {params => {sk => $current->o ('a1')->{session}->{sk},
                    all => 1}, status => 400, name => 'no server'},
        {params => {sk => $current->o ('a1')->{session}->{sk},
                    server => 'hoge',
                    all => 1}, status => 400, name => 'bad server'},
        {params => {sk => $current->o ('a1')->{session}->{sk},
                    server => 'linktest2'}, status => 400,
         name => 'bad account_link_id'},
        {params => {sk => $current->o ('a1')->{session}->{sk},
                    server => 'linktest2',
                    account_link_id => 124,
                    all => 1}, status => 400,
         name => 'bad account_link_id'},
      ],
    );
  })->then (sub {
    return $current->post (['link', 'delete'], {
      server => 'linktest1',
      sk => $current->o ('a1')->{session}->{sk},
      #sk_context is implied
      all => 1,
    });
  })->then (sub {
    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email', 'foo'],
    }, account => 'a1');
  })->then (sub {
    my $result = $_[0];
    test {
      my $acc = $result->{json};
      is 0+keys %{$acc->{links}}, 1;
      my $link = [values %{$acc->{links}}]->[0];
      ok $link->{account_link_id};
      is $link->{service_name}, 'linktest2';
      ok $link->{created};
      ok $link->{updated};
      is $link->{id}, $current->o ('i3');
      is $link->{key}, $current->o ('k3');
      is $link->{name}, undef;
      is $link->{email}, undef;
      is $link->{foo}, undef;
    } $current->c;
    return $current->post (['link', 'delete'], {
      server => 'linktest1',
      sk => $current->o ('a1')->{session}->{sk},
      #sk_context is implied
      all => 1,
    }); # nop
  })->then (sub {
    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email', 'foo'],
    }, account => 'a1');
  })->then (sub {
    my $result = $_[0];
    test {
      my $acc = $result->{json};
      is 0+keys %{$acc->{links}}, 1;
      my $link = [values %{$acc->{links}}]->[0];
      ok $link->{account_link_id};
      is $link->{service_name}, 'linktest2';
      ok $link->{created};
      ok $link->{updated};
      is $link->{id}, $current->o ('i3');
      is $link->{key}, $current->o ('k3');
      is $link->{name}, undef;
      is $link->{email}, undef;
      is $link->{foo}, undef;
    } $current->c;
  });
} n => 21, name => '/link/delete?all';

RUN;

=head1 LICENSE

Copyright 2015-2021 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
