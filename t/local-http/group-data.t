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
      [['group', 'data'], {
        context_key => $current->o ('g1')->{context_key},
        group_id => $current->o ('g1')->{group_id},
        name => "x{5000}",
        value => "\x{50000}",
      }],
      [
        {bearer => undef, status => 401},
        {bearer => rand, status => 401},
        {method => 'GET', status => 405},
        {params => {
          context_key => $current->o ('g1')->{context_key},
        }, status => 404},
        {params => {
          context_key => $current->o ('g1')->{context_key},
          group_id => int rand 10000000,
        }, status => 404},
        {params => {
          group_id => $current->o ('g1')->{group_id},
        }, status => 404},
        {params => {
          context_key => rand,
          group_id => $current->o ('g1')->{group_id},
        }, status => 404},
      ],
    );
  })->then (sub {
    return $current->post (['group', 'data'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      name => "x{5000}",
      value => "\x{40000}",
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->context;
    return $current->post (['group', 'profiles'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      with_data => ["x{5000}"],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $g = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      is $g->{data}->{"x{5000}"}, "\x{40000}";
    } $current->context;
    return $current->post (['group', 'data'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      name => ["x{5000}", "hogefuga", ''],
      value => ["\x{30000}", 0, 'hoe'],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->context;
    return $current->post (['group', 'data'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->context;
    return $current->post (['group', 'profiles'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      with_data => ["x{5000}", "hogefuga", "", "abcde"],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $g = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      is $g->{data}->{"x{5000}"}, "\x{30000}";
      is $g->{data}->{hogefuga}, '0';
      is $g->{data}->{''}, 'hoe';
      is $g->{data}->{'abcde'}, undef;
    } $current->context;
    return $current->post (['group', 'data'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      name => "hogefuga",
      value => "",
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->context;
    return $current->post (['group', 'profiles'], {
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
      with_data => "hogefuga",
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $g = $result->{json}->{groups}->{$current->o ('g1')->{group_id}};
      is $g->{data}->{hogefuga}, undef;
    } $current->context;
  });
} wait => $wait, n => 10, name => '/group/data';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2017 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
