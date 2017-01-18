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
      [['group', 'owner_status'], {
        context_key => $current->o ('g1')->{context_key},
        group_id => $current->o ('g1')->{group_id},
        owner_status => 4,
      }],
      [
        {bearer => undef, status => 401, name => 'no bearer'},
        {bearer => rand, status => 401, name => 'bad bearer'},
        {method => 'GET', status => 405, name => 'bad method'},
        {params => {owner_status => 4}, status => 404},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          owner_status => 4,
        }, status => 404},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          group_id => int rand 100000000,
          owner_status => 4,
        }, status => 404},
        {params => {
          group_id => $current->o ('g1')->{group_id},
          owner_status => 4,
        }, status => 404},
        {params => {
          context_key => rand,
          group_id => $current->o ('g1')->{group_id},
          owner_status => 4,
        }, status => 404},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          group_id => $current->o ('g1')->{group_id},
        }, status => 400},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          group_id => $current->o ('g1')->{group_id},
          owner_status => 0,
        }, status => 400},
      ],
    );
  })->then (sub {
    return $current->post (['group', 'owner_status'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      owner_status => 6,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    return $current->post (['group', 'profiles'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
    });
  })->then (sub {
    my $result = $_[0];
    my $g1 = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
    test {
      is $g1->{owner_status}, 6;
    } $current->c;
  });
} wait => $wait, n => 3, name => '/group/owner_status';

Test {
  my $current = shift;
  return $current->post (['group', 'create'], {
    context_key => rand,
    owner_status => 7,
  })->then (sub {
    my $result = $_[0];
    return $current->post (['group', 'profiles'], {
      context_key => $result->{json}->{context_key},
      group_id => $result->{json}->{group_id},
    })->then (sub {
      my $result2 = $_[0];
      my $g1 = $result2->{json}->{groups}->{$result->{json}->{group_id}};
      test {
        is $g1->{owner_status}, 7;
      } $current->c;
    });
  });
} wait => $wait, n => 1, name => '/group/create with owner_status';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2017 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
