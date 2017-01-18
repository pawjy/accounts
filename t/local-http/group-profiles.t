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
      [['group', 'profiles'], {
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
      return $current->post (['group', 'profiles'], $test)->then (sub {
        my $result = $_[0];
        test {
          is $result->{status}, 200;
          is 0+keys %{$result->{json}->{groups}}, 0;
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
  });
} wait => $wait, n => 1 + 2 * 5, name => '/group/profiles';

Test {
  my $current = shift;
  return $current->create_group (g1 => {})->then (sub {
    return $current->create_group (g2 => {});
  })->then (sub {
    return $current->post (['group', 'profiles'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => [$current->o ('g1')->{group_id},
                   $current->o ('g2')->{group_id},
                   int rand 1000000],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{groups}}, 1;
      my $g1 = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      is $g1->{group_id}, $current->o ('g1')->{group_id};
      like $result->{res}->content, qr{"group_id"\s*:\s*"};
      ok $g1->{created};
      ok $g1->{updated};
      is $g1->{owner_status}, 1;
      is $g1->{admin_status}, 1;
      is $g1->{data}, undef;
    } $current->c;
  });
} wait => $wait, n => 9, name => '/group/profiles a group';

Test {
  my $current = shift;
  return $current->create_group (g1 => {})->then (sub {
    return $current->create_group (g2 => {
      context_key => $current->o ('g1')->{context_key},
    });
  })->then (sub {
    return $current->post (['group', 'profiles'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => [$current->o ('g1')->{group_id},
                   $current->o ('g2')->{group_id},
                   int rand 1000000],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{groups}}, 2;
      my $g1 = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      is $g1->{group_id}, $current->o ('g1')->{group_id};
      my $g2 = $result->{json}->{groups}->{$current->o ('g2')->{group_id}};
      is $g2->{group_id}, $current->o ('g2')->{group_id};
    } $current->c;
  });
} wait => $wait, n => 4, name => '/group/profiles multiple groups';

Test {
  my $current = shift;
  return $current->create_group (g1 => {
    data => {
      hoge => "\x{50001}\x{424}",
      foo => "",
      bax => "0",
    },
  })->then (sub {
    return $current->create_group (g2 => {
      data => {
        foo => "abcde",
        bax => "5",
      },
      context_key => $current->o ('g1')->{context_key},
    });
  })->then (sub {
    return $current->post (['group', 'profiles'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => [$current->o ('g1')->{group_id},
                   $current->o ('g2')->{group_id}],
      with_data => [qw(hoge foo bax abc)],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $g1 = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      my $g2 = $result->{json}->{groups}->{$current->o ('g2')->{group_id}};
      is $g1->{data}->{hoge}, "\x{50001}\x{424}";
      is $g1->{data}->{foo}, undef;
      is $g1->{data}->{bax}, "0";
      is $g1->{data}->{abc}, undef;
      is $g2->{data}->{hoge}, undef;
      is $g2->{data}->{foo}, "abcde";
      is $g2->{data}->{bax}, "5";
      is $g2->{data}->{abc}, undef;
    } $current->c;
  });
} wait => $wait, n => 8, name => '/group/profiles with data';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2017 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
