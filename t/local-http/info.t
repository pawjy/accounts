use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  my $name = "\x{53533}" . rand;
  return $current->create_account (a1 => {name => $name})->then (sub {
    return $current->are_errors (
      [['info'], {
        sk => $current->o ('a1')->{session}->{sk},
      }],
      [
        {method => 'GET', status => 405, name => 'Bad method'},
        {bearer => undef, status => 401, name => 'No bearer'},
        {bearer => rand, status => 401, name => 'Bad bearer'},
      ],
    );
  })->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('a1')->{session}->{sk},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $current->o ('a1')->{account_id};
      like $result->{res}->body_bytes, qr{"account_id"\s*:\s*"};
      is $result->{json}->{name}, $name;
    } $current->c;
  });
} n => 5, name => '/info with accounted session';

Test {
  my $current = shift;
  return $current->create_session (s1 => {})->then (sub {
    return $current->post (['info'], {});
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, undef;
      is $result->{json}->{name}, undef;
    } $current->c;
  });
} n => 3, name => '/info no session';

Test {
  my $current = shift;
  return $current->create_session (s1 => {})->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('s1')->{sk},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, undef;
      is $result->{json}->{name}, undef;
    } $current->c;
  });
} n => 3, name => '/info has anon session';

Test {
  my $current = shift;
  return $current->create_session (s1 => {})->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('s1')->{sk},
      with_linked => ['id', 'realname', 'icon_url'],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, undef;
      is $result->{json}->{name}, undef;
      is $result->{linked}, undef;
    } $current->c;
  });
} n => 4, name => '/info with linked (no match)';

Test {
  my $current = shift;
  return $current->post (['info'], {sk => 'gfaeaaaaa'})->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, undef;
      is $result->{json}->{name}, undef;
    } $current->c;
  });
} n => 3, name => '/info bad session';

Test {
  my $current = shift;
  my $v1 = "\x{53533}" . rand;
  my $v2 = rand;
  return $current->create_account (a1 => {data => {
    name => $v1,
    hoge => $v2,
  }})->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('a1')->{session}->{sk},
      with_data => ['name', 'hoge', 'foo'],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $current->o ('a1')->{account_id};
      is $result->{json}->{data}->{name}, $v1;
      is $result->{json}->{data}->{hoge}, $v2;
      is $result->{json}->{data}->{foo}, undef;
    } $current->c;
  });
} n => 5, name => '/info with data';

Test {
  my $current = shift;
  return $current->create_group (g1 => {})->then (sub {
    return $current->post (['info'], {
      sk => undef,
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, undef;
      is $result->{json}->{group_membership}, undef;
      is $result->{json}->{group}->{group_id}, $current->o ('g1')->{group_id};
      like $result->{res}->body_bytes, qr{"group_id"\s*:\s*"};
      is $result->{json}->{group}->{owner_status}, 1;
      is $result->{json}->{group}->{admin_status}, 1;
      ok $result->{json}->{group}->{created};
      ok $result->{json}->{group}->{updated};
    } $current->c;
  });
} n => 9, name => '/info no sk, group_id';

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->create_group (g1 => {members => [{
      account_id => $current->o ('a1')->{account_id},
      user_status => 3,
      owner_status => 6,
      member_type => 9,
    }]});
  })->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('a1')->{session}->{sk},
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $current->o ('a1')->{account_id};
      is $result->{json}->{group_membership}->{user_status}, 3;
      is $result->{json}->{group_membership}->{owner_status}, 6;
      is $result->{json}->{group_membership}->{member_type}, 9;
      is $result->{json}->{group}->{group_id}, $current->o ('g1')->{group_id};
      like $result->{res}->body_bytes, qr{"group_id"\s*:\s*"};
      is $result->{json}->{group}->{owner_status}, 1;
      is $result->{json}->{group}->{admin_status}, 1;
      ok $result->{json}->{group}->{created};
      ok $result->{json}->{group}->{updated};
    } $current->c;
  });
} n => 11, name => '/info with sk, group_id';

for (
  [[[1], [1], [0]] => 1, "matched 1"],
  [[[1,2], [1], [0]] => 1, "matched 2"],
  [[[1,2], [1], [1]] => 0, "bad version"],
  [[[2], [1], [0]] => 0, "bad user status"],
  [[[1], [4], [0]] => 0, "bad admin status"],
) {
  my ($input, $expected, $name) = @$_;
  Test {
    my $current = shift;
    return $current->create_account (a1 => {})->then (sub {
      return $current->post (['info'], {
        sk => $current->o ('a1')->{session}->{sk},
        user_status => $input->[0],
        admin_status => $input->[1],
        terms_version => $input->[2],
      });
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{status}, 200;
        if ($expected) {
          is $result->{json}->{account_id}, $current->o ('a1')->{account_id};
        } else {
          is $result->{json}->{account_id}, undef;
        }
      } $current->c;
    });
  } n => 2, name => ['/info account status filter', $name];
}

for (
  [[[6], [7]] => 1, "matched 1"],
  [[[6,2], [7]] => 1, "matched 2"],
  [[[6,2], [1]] => 0, "bad version"],
  [[[2], [7]] => 0, "bad user status"],
) {
  my ($input, $expected, $name) = @$_;
  Test {
    my $current = shift;
    return $current->create_account (a1 => {})->then (sub {
      return $current->create_group (g1 => {
        members => ['a1'],
        admin_status => 6,
        owner_status => 7,
      });
    })->then (sub {
      return $current->post (['info'], {
        sk => $current->o ('a1')->{session}->{sk},
        context_key => $current->o ('g1')->{context_key},
        group_id => $current->o ('g1')->{group_id},
        group_admin_status => $input->[0],
        group_owner_status => $input->[1],
      });
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{status}, 200;
        if ($expected) {
          is $result->{json}->{group}->{group_id}, $current->o ('g1')->{group_id};
          ok $result->{json}->{group_membership};
        } else {
          is $result->{json}->{group}, undef;
          is $result->{json}->{group_membership}, undef;
        }
      } $current->c;
    });
  } n => 3, name => ['/info group status filter', $name];
}

for (
  [[[6], [7], [9]] => 1, "matched 1"],
  [[[6,2], [7], [9]] => 1, "matched 2"],
  [[[6,2], [1], [9]] => 0, "bad version"],
  [[[2], [7], [9]] => 0, "bad user status"],
  [[[6], [7], [4]] => 0, "bad member type"],
) {
  my ($input, $expected, $name) = @$_;
  Test {
    my $current = shift;
    return $current->create_account (a1 => {})->then (sub {
      return $current->create_group (g1 => {
        members => [{
          account_id => $current->o ('a1')->{account_id},
          user_status => 6,
          owner_status => 7,
          member_type => 9,
        }],
      });
    })->then (sub {
      return $current->post (['info'], {
        sk => $current->o ('a1')->{session}->{sk},
        context_key => $current->o ('g1')->{context_key},
        group_id => $current->o ('g1')->{group_id},
        group_membership_user_status => $input->[0],
        group_membership_owner_status => $input->[1],
        group_membership_member_type => $input->[2],
      });
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{status}, 200;
        is $result->{json}->{group}->{group_id}, $current->o ('g1')->{group_id};
        if ($expected) {
          ok $result->{json}->{group_membership};
        } else {
          is $result->{json}->{group_membership}, undef;
        }
      } $current->c;
    });
  } n => 3, name => ['/info group member status filter', $name];
}

Test {
  my $current = shift;
  return $current->create_account (a1 => {data => {
    hoge => "\x{5000}",
    fuga => 0,
  }})->then (sub {
    return $current->create_group (g1 => {
      data => {
        hoge => 1344,
      },
      members => [{
        account_id => $current->o ('a1')->{account_id},
        data => {fuga => 21},
      }],
    });
  })->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('a1')->{session}->{sk},
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      with_data => ['hoge', 'fuga', 'abc'],
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{json}->{data}->{hoge}, "\x{5000}";
        is $result->{json}->{data}->{fuga}, 0;
        is $result->{json}->{data}->{abc}, undef;
        is $result->{json}->{group}->{data}, undef;
        is $result->{json}->{group_membership}->{data}, undef;
      } $current->c;
    });
  })->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('a1')->{session}->{sk},
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      with_group_data => ['hoge', 'fuga', 'abc'],
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{json}->{data}, undef;
        is $result->{json}->{group}->{data}->{hoge}, "1344";
        is $result->{json}->{group}->{data}->{fuga}, undef;
        is $result->{json}->{group}->{data}->{abc}, undef;
        is $result->{json}->{group_membership}->{data}, undef;
      } $current->c;
    });
  })->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('a1')->{session}->{sk},
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      with_group_member_data => ['hoge', 'fuga', 'abc'],
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{json}->{data}, undef;
        is $result->{json}->{group}->{data}, undef;
        is $result->{json}->{group_membership}->{data}->{hoge}, undef;
        is $result->{json}->{group_membership}->{data}->{fuga}, "21";
        is $result->{json}->{group_membership}->{data}->{abc}, undef;
      } $current->c;
    });
  });
} n => 15, name => ['/info with group data'];

Test {
  my $current = shift;
  return $current->create (
    [a1 => account => {}],
    [g1 => group => {members => [
      {account => 'a1', member_type => 3, user_status => 4, owner_status => 5},
    ], context_key => $current->generate_context_key (k1 => {})}],
    [g2 => group => {members => [
      {account => 'a1', member_type => 6, user_status => 7, owner_status => 8},
    ], context_key => $current->o ('k1')}],
    [g3 => group => {members => [
      {account => 'a1', member_type => 9, user_status => 10, owner_status => 11},
    ], context_key => $current->o ('k1')}],
    [g4 => group => {}],
    [g5 => group => {members => [
      {account => 'a1', member_type => 9, user_status => 10, owner_status => 11},
    ], context_key => $current->generate_context_key ('k2' => {})}],
  )->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('a1')->{session}->{sk},
      context_key => $current->o ('k1'),
      group_id => $current->o ('g1')->{group_id},
      additional_group_id => [
        $current->o ('g2')->{group_id},
        $current->o ('g3')->{group_id},
        rand,
        $current->o ('g4')->{group_id},
        $current->o ('g5')->{group_id},
      ],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $m1 = $result->{json}->{group_membership};
      is $m1->{member_type}, 3;
      is $m1->{user_status}, 4;
      is $m1->{owner_status}, 5;
      is 0+keys %{$result->{json}->{additional_group_memberships}}, 2;
      my $m2 = $result->{json}->{additional_group_memberships}->{$current->o ('g2')->{group_id}};
      is $m2->{member_type}, 6;
      is $m2->{user_status}, 7;
      is $m2->{owner_status}, 8;
      my $m3 = $result->{json}->{additional_group_memberships}->{$current->o ('g3')->{group_id}};
      is $m3->{member_type}, 9;
      is $m3->{user_status}, 10;
      is $m3->{owner_status}, 11;
    } $current->c;
  });
} n => 10, name => 'additional_group_ids';

Test {
  my $current = shift;
  return $current->create (
    [a1 => account => {}],
    [g1 => group => {members => [
      {account => 'a1', member_type => 3, user_status => 4, owner_status => 5},
    ], context_key => $current->generate_context_key (k1 => {})}],
  )->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('a1')->{session}->{sk},
      context_key => $current->o ('k1'),
      group_id => $current->o ('g1')->{group_id},
      additional_group_id => [
        $current->o ('g1')->{group_id},
      ],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $m1 = $result->{json}->{group_membership};
      is $m1->{member_type}, 3;
      is $m1->{user_status}, 4;
      is $m1->{owner_status}, 5;
      is 0+keys %{$result->{json}->{additional_group_memberships}}, 1;
      my $m2 = $result->{json}->{additional_group_memberships}->{$current->o ('g1')->{group_id}};
      is $m2->{member_type}, 3;
      is $m2->{user_status}, 4;
      is $m2->{owner_status}, 5;
    } $current->c;
  });
} n => 7, name => 'additional_group_ids has group_id';

RUN;

=head1 LICENSE

Copyright 2015-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
