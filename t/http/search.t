use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->are_errors (
    [['search'], {q => rand}],
    [
      {method => 'GET', status => 405},
      {bearer => undef, status => 401},
    ],
  )->then (sub {
    return $current->post (['search'], {});
  })->then (sub {
    my $result = $_[0];
    test {
      is ref $result->{json}->{accounts}, 'HASH';
      is 0+keys %{$result->{json}->{accounts} or {}}, 0;
    } $current->c;
  });
} n => 3, name => '/search no q';

Test {
  my $current = shift;
  return $current->post (['search'], {
    q => $current->generate_text (t1 => {}),
  })->then (sub {
    my $result = $_[0];
    test {
      is ref $result->{json}->{accounts}, 'HASH';
      is 0+keys %{$result->{json}->{accounts} or {}}, 0;
    } $current->c;
  });
} n => 2, name => '/search not found';

RUN;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
