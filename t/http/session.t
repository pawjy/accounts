use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->are_errors (
    [['session'], {sk_context => rand}],
    [
      {method => 'GET', status => 405},
      {bearer => undef, status => 401},
      {params => {}, status => 400, reason => 'No |sk_context|'},
    ],
  )->then (sub {
    return $current->post (['session'], {
      sk_context => 'hoe',
    });
  })->then (sub {
    my $result = $_[0];
    test {
      like $result->{json}->{sk}, qr{^\w+$};
      ok $result->{json}->{set_sk};
      ok $result->{json}->{sk_expires} > time;
    } $current->c;
  });
} n => 4, name => '/session new session';

Test {
  my $current = shift;
  return $current->post (['session'], {
    sk_context => $current->generate_context_key (k1 => {}),
  })->then (sub {
    my $result = $_[0];
    $current->set_o (s1 => $result->{json});
    return $current->post (['session'], {
      sk => $current->o ('s1')->{sk},
      sk_context => $current->o ('k1'),
    });
  })->then (sub {
    my $json = $_[0]->{json};
    test {
      is $json->{sk}, $current->o ('s1')->{sk};
      ok not $json->{set_sk};
      ok $json->{sk_expires}, $current->o ('s1')->{sk_expires};
    } $current->c;
  })->then (sub {
    return $current->post (['session'], {
      sk => $current->o ('s1')->{sk},
      sk_context => rand,
    });
  })->then (sub {
    my $json = $_[0]->{json};
    test {
      isnt $json->{sk}, $current->o ('s1')->{sk};
      ok $json->{set_sk};
    } $current->c, name => 'different sk_context';
  });
} n => 5, name => '/session existing session';

Test {
  my $current = shift;
  return $current->post (['session'], {
    sk => 'hogeaaaaa', sk_context => 'hoe',
  })->then (sub {
    my $json = $_[0]->{json};
    test {
      like $json->{sk}, qr{^\w+$};
      isnt $json->{sk}, 'hogeaaaaa';
      ok $json->{set_sk};
      ok $json->{sk_expires} > time;
    } $current->c;
  });
} n => 4, name => '/session bad session';

RUN;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
