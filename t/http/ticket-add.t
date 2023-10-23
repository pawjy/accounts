use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create_session (1)->then (sub {
    return $current->are_errors (
      [['ticket', 'add'], {}, session => 1],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {session => undef, status => 400},
      ],
    );
  })->then (sub {
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{tickets}, undef;
    } $current->c;
    return $current->post (['info'], {
      with_tickets => 1,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{tickets}}, 0;
    } $current->c;
    return $current->post (['ticket', 'add'], {
    }, session => 1); # nop
  })->then (sub {
    return $current->post (['info'], {
      with_tickets => 1,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{tickets}}, 0;
    } $current->c;
    return $current->post (['ticket', 'add'], {
      ticket => [$current->generate_key (k1 => {})],
    }, session => 1);
  })->then (sub {
    return $current->post (['info'], {
      with_tickets => 1,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      ok $result->{json}->{tickets}->{$current->o ('k1')};
      is 0+keys %{$result->{json}->{tickets}}, 1;
    } $current->c;
    return $current->post (['ticket', 'add'], {
      ticket => [$current->generate_key (k2 => {}),
                 $current->generate_key (k3 => {})],
    }, session => 1);
  })->then (sub {
    return $current->post (['info'], {
      with_tickets => 1,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      ok $result->{json}->{tickets}->{$current->o ('k1')};
      ok $result->{json}->{tickets}->{$current->o ('k2')};
      ok $result->{json}->{tickets}->{$current->o ('k3')};
      is 0+keys %{$result->{json}->{tickets}}, 3;
    } $current->c;
  });
} n => 10, name => 'session ticket';

RUN;

=head1 LICENSE

Copyright 2023 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
