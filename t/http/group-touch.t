use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create_group (g1 => {})->then (sub {
    return $current->are_errors (
      [['group', 'touch'], {
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
      my $test = shift;
      return $current->post (['group', 'touch'], $test)->then (sub {
        my $result = $_[0];
        test {
          is $result->{status}, 200;
          is $result->{json}->{changed}, 0;
        } $current->c, name => 'Group not found';
      });
    } [
      {},
      {
        context_key => $current->o ('g1')->{context_key},
      },
      {
        context_key => $current->o ('g1')->{context_key},
        group_id => int rand 100000000,
      },
      {
        group_id => $current->o ('g1')->{group_id},
      },
      {
        context_key => rand,
        group_id => $current->o ('g1')->{group_id},
      },
    ];
  })->then (sub {
    return $current->post (['group', 'touch'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{changed}, 1;
    } $current->c;
    return $current->post (['group', 'profiles'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
    });
  })->then (sub {
    my $result = $_[0];
    my $g1 = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
    test {
      ok $g1->{updated} > $g1->{created};
    } $current->c;
    my $t1 = $g1->{updated};
    return $current->post (['group', 'touch'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
    })->then (sub {
      return $current->post (['group', 'profiles'], {
        context_key => $current->o ('g1')->{context_key},
        group_id => $current->o ('g1')->{group_id},
      });
    })->then (sub {
      my $result = $_[0];
      my $g1 = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      test {
        ok $g1->{updated} > $t1;
      } $current->c;
    });
  });
} n => 15, name => '/group/touch';

RUN;

=head1 LICENSE

Copyright 2017-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
