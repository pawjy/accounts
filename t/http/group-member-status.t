use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->create_group (g1 => {});
  })->then (sub {
    return $current->are_errors (
      [['group', 'member', 'status'], {
        context_key => $current->o ('g1')->{context_key},
        group_id => $current->o ('g1')->{group_id},
        account_id => $current->o ('a1')->{account_id},
      }],
      [
        {bearer => undef, status => 401, name => 'no bearer'},
        {bearer => rand, status => 401, name => 'bad bearer'},
        {method => 'GET', status => 405, name => 'bad method'},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          group_id => $current->o ('g1')->{group_id},
        }, status => 404},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          account_id => $current->o ('a1')->{account_id},
        }, status => 404},
        {params => {
          group_id => $current->o ('g1')->{group_id},
          account_id => $current->o ('a1')->{account_id},
        }, status => 404},
        {params => {
          context_key => rand,
          group_id => $current->o ('g1')->{group_id},
          account_id => $current->o ('a1')->{account_id},
        }, status => 404},
      ],
    );
  })->then (sub {
    return promised_for {
      my ($params, $expected, $name) = @{$_[0]};
      return $current->post (['group', 'member', 'status'], {
        context_key => $current->o ('g1')->{context_key},
        group_id => $current->o ('g1')->{group_id},
        account_id => $current->o ('a1')->{account_id},
        member_type => $params->[0],
        owner_status => $params->[1],
        user_status => $params->[2],
      })->then (sub {
        my $result = $_[0];
        test {
          is $result->{status}, 200;
        } $current->c, name => $name;
        return $current->post (['group', 'members'], {
          context_key => $current->o ('g1')->{context_key},
          group_id => $current->o ('g1')->{group_id},
        });
      })->then (sub {
        my $result = $_[0];
        test {
          my $m1 = $result->{json}->{memberships}->{$current->o ('a1')->{account_id}};
          is $m1->{account_id}, $current->o ('a1')->{account_id};
          like $result->{res}->content, qr{"account_id"\s*:\s*"};
          ok $m1->{created};
          ok $m1->{updated};
          is $m1->{member_type}, $expected->[0];
          is $m1->{owner_status}, $expected->[1];
          is $m1->{user_status}, $expected->[2];
        } $current->c, name => $name;
      });
    } [
      [[undef, undef, 65] => [0, 0, 65], "initial, user only"],
      [[4, 5, 21] => [4, 5, 21], "all fields"],
      [[0, 0, 0] => [0, 0, 0], "all fields reset"],
      [[3, undef, undef] => [3, 0, 0], undef],
      [[undef, undef, undef] => [3, 0, 0], undef],
    ];
  });
} n => 1 + 8 * 5, name => '/group/member/status';

RUN;

=head1 LICENSE

Copyright 2017-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
