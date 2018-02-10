use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create_group (g1 => {
    owner_status => 2,
    admin_status => 5,
  })->then (sub {
    return $current->create_group (g2 => {
      context_key => $current->o ('g1')->{context_key},
      owner_status => 1,
      admin_status => 4,
    });
  })->then (sub {
    return $current->are_errors (
      [['group', 'list'], {
        context_key => $current->o ('g1')->{context_key},
      }],
      [
        {bearer => undef, status => 401, name => 'no bearer'},
        {bearer => rand, status => 401, name => 'bad bearer'},
        {method => 'GET', status => 405, name => 'bad method'},
      ],
    );
  })->then (sub {
    return $current->post (['group', 'list'], {
      context_key => $current->o ('g1')->{context_key},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{groups}}, 2;
      my $m1 = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      is $m1->{group_id}, $current->o ('g1')->{group_id};
      like $result->{res}->content, qr{"group_id"\s*:\s*"};
      ok $m1->{created};
      ok $m1->{updated};
      is $m1->{owner_status}, 2;
      is $m1->{admin_status}, 5;
      my $m2 = $result->{json}->{groups}->{$current->o ('g2')->{group_id}};
      is $m2->{group_id}, $current->o ('g2')->{group_id};
      is $m2->{owner_status}, 1;
      is $m2->{admin_status}, 4;
    } $current->c;
  });
} n => 11, name => '/group/list';

Test {
  my $current = shift;
  return $current->create_group (g1 => {members => []})->then (sub {
    return $current->create_group (g2 => {members => [],
      context_key => $current->o ('g1')->{context_key},
    });
  })->then (sub {
    return $current->create_group (g3 => {members => [],
      context_key => $current->o ('g1')->{context_key},
    });
  })->then (sub {
    return $current->are_errors (
      [['group', 'list'], {}],
      [
        {params => {
          context_key => $current->o ('g1')->{context_key},
          limit => 2000,
        }, status => 400, reason => 'Bad |limit|'},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          ref => 'abcde',
        }, status => 400, reason => 'Bad |ref|'},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          ref => '+532233.333,10000',
        }, status => 400, reason => 'Bad |ref| offset'},
      ],
    );
  })->then (sub {
    return $current->post (['group', 'list'], {
      context_key => $current->o ('g1')->{context_key},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{groups}}, 2;
      ok $result->{json}->{groups}->{$current->o ('g3')->{group_id}};
      ok $result->{json}->{groups}->{$current->o ('g2')->{group_id}};
      ok $result->{json}->{next_ref};
      ok $result->{json}->{has_next};
    } $current->c;
    return $current->post (['group', 'list'], {
      context_key => $current->o ('g1')->{context_key},
      ref => $result->{json}->{next_ref},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{groups}}, 1;
      ok $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      ok $result->{json}->{next_ref};
      ok ! $result->{json}->{has_next};
    } $current->c;
    return $current->post (['group', 'list'], {
      context_key => $current->o ('g1')->{context_key},
      ref => $result->{json}->{next_ref},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{groups}}, 0;
      ok $result->{json}->{next_ref};
      ok ! $result->{json}->{has_next};
    } $current->c;
    return $current->post (['group', 'list'], {
      context_key => $current->o ('g1')->{context_key},
      ref => $result->{json}->{next_ref},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{groups}}, 0;
      ok $result->{json}->{next_ref};
      ok ! $result->{json}->{has_next};
    } $current->c;
  });
} n => 22, name => '/group/list paging';

Test {
  my $current = shift;
  return $current->create_group (g1 => {
    data => {"x{5000}" => "\x{40000}"},
  })->then (sub {
    return $current->create_group (g2 => {
      context_key => $current->o ('g1')->{context_key},
      data => {abc => "0"},
    });
  })->then (sub {
    return $current->post (['group', 'list'], {
      context_key => $current->o ('g1')->{context_key},
      with_data => ["x{5000}", "abc"],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $g1 = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      is $g1->{data}->{"x{5000}"}, "\x{40000}";
      is $g1->{data}->{abc}, undef;
      my $g2 = $result->{json}->{groups}->{$current->o ('g2')->{group_id}};
      is $g2->{data}->{"x{5000}"}, undef;
      is $g2->{data}->{abc}, "0";
    } $current->c;
  });
} n => 4, name => '/group/list with data';

Test {
  my $current = shift;
  return $current->create_group (g1 => {
    owner_status => 2,
    admin_status => 5,
  })->then (sub {
    return $current->create_group (g2 => {
      context_key => $current->o ('g1')->{context_key},
      owner_status => 1,
      admin_status => 4,
    });
  })->then (sub {
    return $current->post (['group', 'list'], {
      context_key => $current->o ('g1')->{context_key},
      owner_status => [3, 2],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{groups}}, 1;
      ok $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      ok ! $result->{json}->{groups}->{$current->o ('g2')->{group_id}};
    } $current->c;
  });
} n => 3, name => '/group/list status filtered';

RUN;

=head1 LICENSE

Copyright 2017-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
