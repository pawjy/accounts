use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

my $wait = web_server;

Test {
  my $current = shift;
  return $current->create_group (g1 => {})->then (sub {
    return $current->are_errors (
      [['group', 'touch'], {
        sk_context => $current->o ('g1')->{sk_context},
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
      my $test = shift;
      return $current->post (['group', 'touch'], $test)->then (sub {
        my $result = $_[0];
        test {
          is $result->{status}, 200;
          is $result->{json}->{changed}, 0;
        } $current->context, name => 'Group not found';
      });
    } [
      {},
      {
        sk_context => $current->o ('g1')->{sk_context},
      },
      {
        sk_context => $current->o ('g1')->{sk_context},
        group_id => int rand 100000000,
      },
      {
        group_id => $current->o ('g1')->{group_id},
      },
      {
        sk_context => rand,
        group_id => $current->o ('g1')->{group_id},
      },
    ];
  })->then (sub {
    return $current->post (['group', 'touch'], {
      sk_context => $current->o ('g1')->{sk_context},
      group_id => $current->o ('g1')->{group_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{changed}, 1;
    } $current->context;
    return $current->post (['group', 'profiles'], {
      sk_context => $current->o ('g1')->{sk_context},
      group_id => $current->o ('g1')->{group_id},
    });
  })->then (sub {
    my $result = $_[0];
    my $g1 = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
    test {
      ok $g1->{updated} > $g1->{created};
    } $current->context;
    my $t1 = $g1->{updated};
    return $current->post (['group', 'touch'], {
      sk_context => $current->o ('g1')->{sk_context},
      group_id => $current->o ('g1')->{group_id},
    })->then (sub {
      return $current->post (['group', 'profiles'], {
        sk_context => $current->o ('g1')->{sk_context},
        group_id => $current->o ('g1')->{group_id},
      });
    })->then (sub {
      my $result = $_[0];
      my $g1 = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      test {
        ok $g1->{updated} > $t1;
      } $current->context;
    });
  });
} wait => $wait, n => 15, name => '/group/touch';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2017 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
