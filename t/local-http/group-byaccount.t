use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create_group (g1 => {})->then (sub {
    return $current->create_group (g2 => {
      context_key => $current->o ('g1')->{context_key},
    });
  })->then (sub {
    return $current->create_account (a1 => {});
  })->then (sub {
    return $current->post (['group', 'member', 'status'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      account_id => $current->o ('a1')->{account_id},
      user_status => 5,
      owner_status => 2,
      member_type => 5,
    });
  })->then (sub {
    return $current->post (['group', 'member', 'status'], {
      context_key => $current->o ('g2')->{context_key},
      group_id => $current->o ('g2')->{group_id},
      account_id => $current->o ('a1')->{account_id},
      user_status => 4,
      owner_status => 1,
      member_type => 9,
    });
  })->then (sub {
    return $current->are_errors (
      [['group', 'byaccount'], {
        context_key => $current->o ('g1')->{context_key},
        account_id => $current->o ('a1')->{account_id},
      }],
      [
        {bearer => undef, status => 401, name => 'no bearer'},
        {bearer => rand, status => 401, name => 'bad bearer'},
        {method => 'GET', status => 405, name => 'bad method'},
      ],
    );
  })->then (sub {
    return promised_for {
      my ($params, $name) = @{$_[0]};
      return $current->post (['group', 'members'], $params)->then (sub {
        my $result = $_[0];
        test {
          is $result->{status}, 200;
          is 0+keys %{$result->{json}->{members}}, 0;
        } $current->c, name => $name;
      });
    } [
      [{
        context_key => $current->o ('g1')->{context_key},
      }, "context_key only"],
      [{
        account_id => $current->o ('a1')->{account_id},
      }, "group_id only"],
      [{
        context_key => rand,
        account_id => $current->o ('a1')->{account_id},
      }, "bad context_key"],
    ];
  })->then (sub {
    return $current->post (['group', 'byaccount'], {
      context_key => $current->o ('g1')->{context_key},
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{memberships}}, 2;
      my $m1 = $result->{json}->{memberships}->{$current->o ('g1')->{group_id}};
      is $m1->{group_id}, $current->o ('g1')->{group_id};
      like $result->{res}->content, qr{"group_id"\s*:\s*"};
      ok $m1->{created};
      ok $m1->{updated};
      is $m1->{member_type}, 5;
      is $m1->{owner_status}, 2;
      is $m1->{user_status}, 5;
      my $m2 = $result->{json}->{memberships}->{$current->o ('g2')->{group_id}};
      is $m2->{group_id}, $current->o ('g2')->{group_id};
      is $m2->{member_type}, 9;
      is $m2->{owner_status}, 1;
      is $m2->{user_status}, 4;
    } $current->c;
  });
} n => 2*3 + 13, name => '/group/byaccount';

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->create_group (g1 => {members => ['a1']});
  })->then (sub {
    return $current->create_group (g2 => {members => ['a1'],
      context_key => $current->o ('g1')->{context_key},
    });
  })->then (sub {
    return $current->create_group (g3 => {members => ['a1'],
      context_key => $current->o ('g1')->{context_key},
    });
  })->then (sub {
    return $current->are_errors (
      [['group', 'byaccount'], {}],
      [
        {params => {
          context_key => $current->o ('g1')->{context_key},
          account_id => $current->o ('a1')->{account_id},
          limit => 2000,
        }, status => 400, reason => 'Bad |limit|'},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          account_id => $current->o ('a1')->{account_id},
          ref => 'abcde',
        }, status => 400, reason => 'Bad |ref|'},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          account_id => $current->o ('a1')->{account_id},
          ref => '+532233.333,10000',
        }, status => 400, reason => 'Bad |ref| offset'},
      ],
    );
  })->then (sub {
    return $current->post (['group', 'byaccount'], {
      context_key => $current->o ('g1')->{context_key},
      account_id => $current->o ('a1')->{account_id},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{memberships}}, 2;
      ok $result->{json}->{memberships}->{$current->o ('g3')->{group_id}};
      ok $result->{json}->{memberships}->{$current->o ('g2')->{group_id}};
      ok $result->{json}->{next_ref};
      ok $result->{json}->{has_next};
    } $current->c;
    return $current->post (['group', 'byaccount'], {
      context_key => $current->o ('g1')->{context_key},
      account_id => $current->o ('a1')->{account_id},
      ref => $result->{json}->{next_ref},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{memberships}}, 1;
      ok $result->{json}->{memberships}->{$current->o ('g1')->{group_id}};
      ok $result->{json}->{next_ref};
      ok ! $result->{json}->{has_next};
    } $current->c;
    return $current->post (['group', 'byaccount'], {
      context_key => $current->o ('g1')->{context_key},
      account_id => $current->o ('a1')->{account_id},
      ref => $result->{json}->{next_ref},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{memberships}}, 0;
      ok $result->{json}->{next_ref};
      ok ! $result->{json}->{has_next};
    } $current->c;
    return $current->post (['group', 'byaccount'], {
      context_key => $current->o ('g1')->{context_key},
      account_id => $current->o ('a1')->{account_id},
      ref => $result->{json}->{next_ref},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{memberships}}, 0;
      ok $result->{json}->{next_ref};
      ok ! $result->{json}->{has_next};
    } $current->c;
  });
} n => 22, name => '/group/byaccount paging';

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->create_group (g1 => {members => ['a1']});
  })->then (sub {
    return $current->create_group (g2 => {
      members => ['a1'],
      context_key => $current->o ('g1')->{context_key},
    });
  })->then (sub {
    return $current->post (['group', 'member', 'data'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      account_id => $current->o ('a1')->{account_id},
      name => ["x{5000}"],
      value => ["\x{40000}"],
    });
  })->then (sub {
    return $current->post (['group', 'member', 'data'], {
      context_key => $current->o ('g2')->{context_key},
      group_id => $current->o ('g2')->{group_id},
      account_id => $current->o ('a1')->{account_id},
      name => ["abc"],
      value => ["0"],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    return $current->post (['group', 'byaccount'], {
      context_key => $current->o ('g1')->{context_key},
      account_id => $current->o ('a1')->{account_id},
      with_data => ["x{5000}", "abc"],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $g1 = $result->{json}->{memberships}->{$current->o ('g1')->{group_id}};
      is $g1->{data}->{"x{5000}"}, "\x{40000}";
      is $g1->{data}->{abc}, undef;
      my $g2 = $result->{json}->{memberships}->{$current->o ('g2')->{group_id}};
      is $g2->{data}->{"x{5000}"}, undef;
      is $g2->{data}->{abc}, "0";
    } $current->c;
  });
} n => 5, name => '/group/byaccount with data';

Test {
  my $current = shift;
  return $current->create (
    [a1 => account => {}],
    [g1 => group => {
      members => ['a1'],
      data => {gd1 => 43},
      context_key => $current->generate_context_key (k1 => {}),
    }],
    [g2 => group => {
      members => ['a1'],
      data => {gd1 => 76, gd2 => 54},
      context_key => $current->o ('k1'),
    }],
  )->then (sub {
    return $current->post (['group', 'byaccount'], {
      context_key => $current->o ('k1'),
      account_id => $current->o ('a1')->{account_id},
      with_group_data => ['gd1', 'gd2'],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $m1 = $result->{json}->{memberships}->{$current->o ('g1')->{group_id}};
      is $m1->{data}, undef;
      is $m1->{group_data}->{gd1}, 43;
      is $m1->{group_data}->{gd2}, undef;
      my $m2 = $result->{json}->{memberships}->{$current->o ('g2')->{group_id}};
      is $m2->{data}, undef;
      is $m2->{group_data}->{gd1}, 76;
      is $m2->{group_data}->{gd2}, 54;
    } $current->c;
  });
} n => 6, name => 'with_group_data';

Test {
  my $current = shift;
  return $current->create (
    [a1 => account => {}],
    [g1 => group => {
      members => [
        {account => 'a1', data => {'gd2' => 64}},
      ],
      data => {gd1 => 43},
      context_key => $current->generate_context_key (k1 => {}),
    }],
    [g2 => group => {
      members => [
        {account => 'a1', data => {'gd3' => 77}},
      ],
      data => {gd1 => 76, gd2 => 54},
      context_key => $current->o ('k1'),
    }],
  )->then (sub {
    return $current->post (['group', 'byaccount'], {
      context_key => $current->o ('k1'),
      account_id => $current->o ('a1')->{account_id},
      with_group_data => ['gd1', 'gd2'],
      with_data => ['gd2', 'gd3'],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $m1 = $result->{json}->{memberships}->{$current->o ('g1')->{group_id}};
      is $m1->{data}->{gd1}, undef;
      is $m1->{data}->{gd2}, 64;
      is $m1->{data}->{gd3}, undef;
      is $m1->{group_data}->{gd1}, 43;
      is $m1->{group_data}->{gd2}, undef;
      is $m1->{group_data}->{gd3}, undef;
      my $m2 = $result->{json}->{memberships}->{$current->o ('g2')->{group_id}};
      is $m2->{data}->{gd1}, undef;
      is $m2->{data}->{gd2}, undef;
      is $m2->{data}->{gd3}, 77;
      is $m2->{group_data}->{gd1}, 76;
      is $m2->{group_data}->{gd2}, 54;
      is $m2->{group_data}->{gd3}, undef;
    } $current->c;
  });
} n => 12, name => 'with_group_data and with_data';

RUN;

=head1 LICENSE

Copyright 2017-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
