use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  my $context = rand;
  my $group_id;
  return $current->are_errors (
    [['group', 'create'], {context_key => $context}],
    [
      {bearer => undef, status => 401},
      {bearer => rand, status => 401},
      {method => 'GET', status => 405},
      {params => {}, status => 400},
    ],
  )->then (sub {
    return $current->post (['group', 'create'], {
      context_key => $context,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      ok $group_id = $result->{json}->{group_id};
      like $result->{res}->content, qr{"group_id"\s*:\s*"};
      is $result->{json}->{context_key}, $context;
    } $current->c;
    return $current->post (['group', 'profiles'], {
      group_id => $group_id,
      context_key => $context,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{groups}}, 1;
      my $g = $result->{json}->{groups}->{$group_id};
      is $g->{group_id}, $group_id;
      like $result->{res}->content, qr{"group_id"\s*:\s*"};
      ok $g->{created};
      ok $g->{updated};
      is $g->{admin_status}, 1;
      is $g->{owner_status}, 1;
    } $current->c;
  });
} n => 12, name => '/group/create';

RUN;

=head1 LICENSE

Copyright 2017-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
