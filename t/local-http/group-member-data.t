use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

my $wait = web_server;

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->create_group (g1 => {members => ['a1']});
  })->then (sub {
    return $current->are_errors (
      [['group', 'member', 'data'], {
        context_key => $current->o ('g1')->{context_key},
        group_id => $current->o ('g1')->{group_id},
        account_id => $current->o ('a1')->{account_id},
        name => "x{5000}",
        value => "\x{50000}",
      }],
      [
        {bearer => undef, status => 401},
        {bearer => rand, status => 401},
        {method => 'GET', status => 405},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          account_id => $current->o ('a1')->{account_id},
        }, status => 404},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          group_id => int rand 10000000,
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
        {params => {
          context_key => $current->o ('g1')->{context_key},
          group_id => $current->o ('g1')->{group_id},
          account_id => int rand 100000000,
        }, status => 404},
      ],
    );
  })->then (sub {
    return $current->post (['group', 'member', 'data'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      account_id => $current->o ('a1')->{account_id},
      name => ["x{5000}", "abc"],
      value => ["\x{40000}", "0"],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->context;
    return $current->post (['group', 'members'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      with_data => ["x{5000}", "abc"],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $g = $result->{json}->{memberships}->{$current->o ('a1')->{account_id}};
      is $g->{data}->{"x{5000}"}, "\x{40000}";
      is $g->{data}->{abc}, "0";
    } $current->context;
  });
} wait => $wait, n => 4, name => '/group/member/data';

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->create_group (g1 => {members => ['a1']});
  })->then (sub {
    return $current->create_group (g2 => {members => ['a1']});
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
    } $current->context;
    return $current->post (['group', 'members'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      with_data => ["x{5000}", "abc"],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $g = $result->{json}->{memberships}->{$current->o ('a1')->{account_id}};
      is $g->{data}->{"x{5000}"}, "\x{40000}";
      is $g->{data}->{abc}, undef;
    } $current->context;
  });
} wait => $wait, n => 3, name => '/group/member/data';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2017 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
