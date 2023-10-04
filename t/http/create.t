use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  my $account_id;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      ok $account_id = $result->{json}->{account_id};
    } $current->c;
    return $current->are_errors (
      [['create'], {}, session => 1],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {session => undef, status => 400},
        {params => {source_data => 'abc'}, status => 400},
      ],
    );
  })->then (sub {
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $account_id;
      is $result->{json}->{name}, $account_id;
      is $result->{json}->{user_status}, 1;
      is $result->{json}->{admin_status}, 1;
      is $result->{json}->{terms_version}, 0;
      ok $result->{json}->{login_time};
      ok $result->{json}->{no_email};
    } $current->c;
    $current->set_o (a1 => $result->{json});
    return $current->post (['log', 'get'], {
      account_id => $current->o ('a1')->{account_id},
      action => 'create',
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      my $item = $result->{json}->{items}->[0];
      ok $item->{log_id};
      is $item->{account_id}, $current->o ('a1')->{account_id};
      is $item->{operator_account_id}, $current->o ('a1')->{account_id};
      ok $item->{timestamp};
      ok $item->{timestamp} < time;
      is $item->{action}, 'create';
      is $item->{ua}, '';
      is $item->{ipaddr}, '';
      ok $item->{data};
    } $current->c;
  });
} n => 21, name => '/create has anon session';

Test {
  my $current = shift;
  my $account_id;
  return $current->post (['create'], {
    sk => 'gfaeaaaaa',
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad session';
    } $current->c;
  });
} n => 2, name => '/create bad session';

Test {
  my $current = shift;
  my $account_id;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {
      name => "\x{65000}",
      user_status => 2,
      admin_status => 6,
      terms_version => 5244,
      source_ipaddr => $current->generate_key (k1 => {}),
      source_ua => $current->generate_key (k2 => {}),
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      ok $account_id = $result->{json}->{account_id};
    } $current->c;
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $account_id;
      is $result->{json}->{name}, "\x{65000}";
      is $result->{json}->{user_status}, 2;
      is $result->{json}->{admin_status}, 6;
      is $result->{json}->{terms_version}, 255;
    } $current->c;
    $current->set_o (a1 => $result->{json});
    return $current->post (['log', 'get'], {
      account_id => $current->o ('a1')->{account_id},
      action => 'create',
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      my $item = $result->{json}->{items}->[0];
      ok $item->{log_id};
      is $item->{account_id}, $current->o ('a1')->{account_id};
      is $item->{operator_account_id}, $current->o ('a1')->{account_id};
      ok $item->{timestamp};
      ok $item->{timestamp} < time;
      is $item->{action}, 'create';
      is $item->{ua}, $current->o ('k2');
      is $item->{ipaddr}, $current->o ('k1');
      ok $item->{data};
    } $current->c;
  });
} n => 18, name => '/create with options';

Test {
  my $current = shift;
  my $account_id;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {
      name => "hoge",
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      ok $account_id = $result->{json}->{account_id};
    } $current->c;
    return $current->post (['create'], {
      name => "\x{65000}",
      user_status => 2,
      admin_status => 6,
      terms_version => 5244,
    }, session => 1);
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Account-associated session';
    } $current->c;
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $account_id;
      is $result->{json}->{name}, "hoge";
    } $current->c;
  });
} n => 6, name => '/create with associated session';

Test {
  my $current = shift;
  my $account_id;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {
      name => "hoge",
      login_time => 12456,
    }, session => 1);
  })->then (sub {
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{login_time}, 12456;
    } $current->c;
  });
} n => 1, name => '/create with login_time';

Test {
  my $current = shift;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {
      source_ipaddr => $current->generate_key (k1 => {}),
      source_ua => $current->generate_key (k2 => {}),
      'source_data' => perl2json_chars ({foo => $current->generate_text (t1 => {})}),
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      $current->set_o (a1 => $result->{json});
    } $current->c;
    return $current->post (['log', 'get'], {
      account_id => $current->o ('a1')->{account_id},
      action => 'create',
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      {
        my $item = $result->{json}->{items}->[0];
        is $item->{ua}, $current->o ('k2');
        is $item->{ipaddr}, $current->o ('k1');
        is $item->{data}->{source_data}->{foo}, $current->o ('t1');
      }
    } $current->c;
    return $current->post (['session', 'get'], {
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      {
        my $item = $result->{json}->{items}->[0];
        ok $item->{session_id};
        like $result->{res}->body_bytes, qr{"session_id":"};
        ok $item->{timestamp};
        ok $item->{timestamp} < time;
        ok $item->{expires};
        is $item->{log_data}->{ua}, $current->o ('k2');
        is $item->{log_data}->{ipaddr}, $current->o ('k1');
        is $item->{log_data}->{source_data}->{foo}, $current->o ('t1');
        is $item->{sk}, undef;
        is $item->{sk_context}, undef;
      }
    } $current->c;
  });
} n => 16, name => 'session log';

RUN;

=head1 LICENSE

Copyright 2015-2023 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
