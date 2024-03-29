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
        source_ipaddr => $current->generate_key (k1 => {}),
        source_ua => $current->generate_key (k2 => {}),
        source_data => perl2json_chars ({foo => $current->generate_text (t1 => {})}),
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
  })->then (sub {
    $current->set_o (a1 => {account_id => $account_id});
    return $current->post (['log', 'get'], {
      account_id => $current->o ('a1')->{account_id},
      action => 'unlink',
    });
  })->then (sub {
    my $result = $_[0];
    test {
      ok 0+@{$result->{json}->{items}};
      my $item = $result->{json}->{items}->[0];
      ok $item->{log_id};
      is $item->{account_id}, $current->o ('a1')->{account_id};
      is $item->{operator_account_id}, $current->o ('a1')->{account_id};
      ok $item->{timestamp};
      ok $item->{timestamp} < time;
      is $item->{action}, 'unlink';
      is $item->{ua}, $current->o ('k2');
      is $item->{ipaddr}, $current->o ('k1');
      ok $item->{data};
      is $item->{data}->{source_operation}, 'link/delete';
      is $item->{data}->{service_name}, 'oauth1server';
      is $item->{data}->{all}, undef;
      is $item->{data}->{source_data}->{foo}, $current->o ('t1');
      like $result->{res}->body_bytes, qr{"account_link_id":"};
      ok $item->{data}->{account_link_id};
    } $current->c;
  });
} n => 36, name => '/link/delete with session';

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
      source_ipaddr => $current->generate_key (k1 => {}),
      source_ua => $current->generate_key (k2 => {}),
      source_data => perl2json_chars ({foo => $current->generate_text (t1 => {})}),
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
    return $current->post (['log', 'get'], {
      account_id => $current->o ('a1')->{account_id},
      action => 'unlink',
    });
  })->then (sub {
    my $result = $_[0];
    test {
      ok 0+@{$result->{json}->{items}};
      my $item = $result->{json}->{items}->[0];
      ok $item->{log_id};
      is $item->{account_id}, $current->o ('a1')->{account_id};
      is $item->{operator_account_id}, $current->o ('a1')->{account_id};
      ok $item->{timestamp};
      ok $item->{timestamp} < time;
      is $item->{action}, 'unlink';
      is $item->{ua}, $current->o ('k2');
      is $item->{ipaddr}, $current->o ('k1');
      ok $item->{data};
      is $item->{data}->{source_operation}, 'link/delete';
      is $item->{data}->{service_name}, 'linktest1';
      ok $item->{data}->{all};
      is $item->{data}->{source_data}->{foo}, $current->o ('t1');
    } $current->c;
  });
} n => 35, name => '/link/delete?all';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $x_account_id1 = int rand 100000;
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
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_id => $x_account_id1,
    }); # user accepted!
  })->then (sub {
    my $result = $_[0];
    my $location = $result->header ('Location');
    my ($base, $query) = split /\?/, $location, 2;
    return $current->post ("/cb?$query", {}, session => 1);
  })->then (sub {
    my $result = $_[0];
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
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $links = $result->{json}->{links};
    my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
    $current->set_o (ls1 => $ls);
    test {
      is 0+@$ls, 2;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_id => $account_id,
      account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id2 } @{$current->o ('ls1')}],
      server => 'oauth2server',
      nolast => 1,
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
    my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
    test {
      is 0+@$ls, 1;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_id => $account_id,
      account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id1 } @{$current->o ('ls1')}],
      server => 'oauth2server',
      nolast => 1,
    });
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $links = $result->{json}->{links};
    my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
    test {
      is 0+@$ls, 1;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_id => $account_id,
      account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id1 } @{$current->o ('ls1')}],
      server => 'oauth2server',
    }); # deleted!
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{links}, undef;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_id => $account_id,
      account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id1 } @{$current->o ('ls1')}],
      server => 'oauth2server',
      nolast => 1,
    });
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $links = $result->{json}->{links};
    my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
    test {
      is 0+@$ls, 0;
    } $current->c;
  });
} n => 8, name => 'delete nolast';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $x_account_id1 = int rand 100000;
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
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_id => $x_account_id1,
    }); # user accepted!
  })->then (sub {
    my $result = $_[0];
    my $location = $result->header ('Location');
    my ($base, $query) = split /\?/, $location, 2;
    return $current->post ("/cb?$query", {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    return $current->post (['link'], {
      server => 'oauth2server_refresh',
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
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $links = $result->{json}->{links};
    my $ls = [grep { $_->{service_name} eq 'oauth2server' or $_->{service_name} eq 'oauth2server_refresh' } values %$links];
    $current->set_o (ls1 => $ls);
    test {
      is 0+@$ls, 2;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_id => $account_id,
      account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id2 } @{$current->o ('ls1')}],
      server => 'oauth2server_refresh',
      nolast => 1,
      nolast_server => ['oauth2server', 'oauth2server_refresh'],
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
    my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
    test {
      is 0+@$ls, 1;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_id => $account_id,
      account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id1 } @{$current->o ('ls1')}],
      server => 'oauth2server',
      nolast => 1,
      nolast_server => ['oauth2server', 'oauth2server_refresh'],
    });
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $links = $result->{json}->{links};
    my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
    test {
      is 0+@$ls, 1;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_id => $account_id,
      account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id1 } @{$current->o ('ls1')}],
      server => 'oauth2server',
      with_emails => 1,
    }); # deleted!
  })->then (sub {
    my $result = $_[0];
    test {
      my $items = $result->{json}->{links};
      is 0+@$items, 0;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_id => $account_id,
      account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id1 } @{$current->o ('ls1')}],
      server => 'oauth2server',
      nolast => 1,
      nolast_server => ['oauth2server', 'oauth2server_refresh'],
    });
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400, $result;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $links = $result->{json}->{links};
    my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
    test {
      is 0+@$ls, 0;
    } $current->c;
  });
} n => 8, name => 'delete nolast_server';

Test {
  my $current = shift;
  my $account_id;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {}, session => 1);
  })->then (sub {
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    $account_id = $result->{json}->{account_id};
    return $current->post (['email', 'input'], {
      addr => $current->generate_email_addr (e1 => {}),
    }, session => 1);
  })->then (sub {
    return $current->post (['email', 'verify'], {
      key => $_[0]->{json}->{key},
    }, session => 1);
  })->then (sub {
    return $current->post (['email', 'input'], {
      addr => $current->generate_email_addr (e2 => {}),
    }, session => 1);
  })->then (sub {
    return $current->post (['email', 'verify'], {
      key => $_[0]->{json}->{key},
    }, session => 1);
  })->then (sub {
    return $current->post (['info'], {with_linked => 'email'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $links = $result->{json}->{links};
    my $ls = [grep { $_->{service_name} eq 'email' } values %$links];
    $current->set_o (ls1 => $ls);
    test {
      is 0+@$ls, 2;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_id => $account_id,
      account_link_id => [map { $_->{account_link_id} } grep { $_->{email} eq $current->o ('e1') } @{$current->o ('ls1')}],
      server => 'email',
      with_emails => 1,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $items = $result->{json}->{links};
      is 0+@$items, 2;
      my $ls1 = [sort { $a->{account_link_id} cmp $b->{account_link_id} } @{$current->o ('ls1')}];
      $items = [sort { $a->{account_link_id} cmp $b->{account_link_id} } @$items];
      is $items->[0]->{account_link_id}, $ls1->[0]->{account_link_id};
      is $items->[0]->{linked_email}, $ls1->[0]->{email};
      is $items->[1]->{account_link_id}, $ls1->[1]->{account_link_id};
      is $items->[1]->{linked_email}, $ls1->[1]->{email};
      ok (
        $items->[0]->{linked_email} eq $current->o ('e1') or
        $items->[0]->{linked_email} eq $current->o ('e2')
      );
    } $current->c;
    return $current->post (['info'], {with_linked => 'email'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $links = $result->{json}->{links};
    my $ls = [grep { $_->{service_name} eq 'email' } values %$links];
    test {
      is 0+@$ls, 1;
      is $ls->[0]->{email}, $current->o ('e2');
    } $current->c;
  });
} n => 9, name => 'with_emails';

RUN;

=head1 LICENSE

Copyright 2015-2023 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
