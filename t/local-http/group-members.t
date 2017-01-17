use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

my $wait = web_server;

Test {
  my $current = shift;
  return $current->create_group (g1 => {})->then (sub {
    return $current->create_account (a1 => {});
  })->then (sub {
    return $current->create_account (a2 => {});
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
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      account_id => $current->o ('a2')->{account_id},
      user_status => 4,
      owner_status => 1,
      member_type => 9,
    });
  })->then (sub {
    return $current->are_errors (
      [['group', 'members'], {
        context_key => $current->o ('g1')->{context_key},
        group_id => $current->o ('g1')->{group_id},
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
        } $current->context, name => $name;
      });
    } [
      [{
        context_key => $current->o ('g1')->{context_key},
      }, "context_key only"],
      [{
        group_id => $current->o ('g1')->{group_id},
      }, "group_id only"],
      [{
        context_key => rand,
        group_id => $current->o ('g1')->{group_id},
      }, "bad context_key"],
    ];
  })->then (sub {
    return $current->post (['group', 'members'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{members}}, 2;
      my $m1 = $result->{json}->{members}->{$current->o ('a1')->{account_id}};
      is $m1->{account_id}, $current->o ('a1')->{account_id};
      like $result->{res}->content, qr{"account_id"\s*:\s*"};
      ok $m1->{created};
      ok $m1->{updated};
      is $m1->{member_type}, 5;
      is $m1->{owner_status}, 2;
      is $m1->{user_status}, 5;
      my $m2 = $result->{json}->{members}->{$current->o ('a2')->{account_id}};
      is $m2->{account_id}, $current->o ('a2')->{account_id};
      is $m2->{member_type}, 9;
      is $m2->{owner_status}, 1;
      is $m2->{user_status}, 4;
    } $current->context;
  });
} wait => $wait, n => 2*3 + 13, name => '/group/members';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2017 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
