use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create (
    [a1 => account => {}],
  )->then (sub {
    return $current->are_errors (
      [['link', 'search'], {
        server => 'linktest1',
        linked_key => rand,
      }],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {params => {server => rand}, status => 400},
        {params => {linked_key => rand}, status => 400},
      ],
    );
  })->then (sub {
    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email', 'foo'],
    }, account => 'a1');
  })->then (sub {
    my $result = $_[0];
    test {
      my $acc = $result->{json};
      is 0+keys %{$acc->{links}}, 0;
    } $current->c;
    return $current->post (['link', 'add'], {
      server => 'linktest1',
      sk => $current->o ('a1')->{session}->{sk},
      #sk_context is implied
      linked_key => $current->generate_key ('k1' => {}),
      linked_id => $current->generate_id (i1 => {}),
    });
  })->then (sub {
    return $current->post (['link', 'search'], {
      server => 'linktest1',
      linked_id => $current->o ('i1'),
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      ok ! $result->{json}->{has_next};
      ok $result->{json}->{next_ref};
      my $item = $result->{json}->{items}->[0];
      ok $item->{account_link_id};
      is $item->{account_id}, $current->o ('a1')->{account_id};
      like $result->{res}->body_bytes, qr{"account_id":"};
      like $result->{res}->body_bytes, qr{"account_link_id":"};
    } $current->c;
  })->then (sub {
    return $current->post (['link', 'search'], {
      server => 'linktest1',
      linked_key => $current->o ('k1'),
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      ok ! $result->{json}->{has_next};
      ok $result->{json}->{next_ref};
      my $item = $result->{json}->{items}->[0];
      ok $item->{account_link_id};
      is $item->{account_id}, $current->o ('a1')->{account_id};
    } $current->c;
    return $current->post (['link', 'search'], {
      server => 'linktest1',
      linked_id => $current->o ('i1'),
      linked_key => $current->o ('k1'),
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      ok ! $result->{json}->{has_next};
      ok $result->{json}->{next_ref};
      my $item = $result->{json}->{items}->[0];
      ok $item->{account_link_id};
      is $item->{account_id}, $current->o ('a1')->{account_id};
    } $current->c;
    return $current->post (['link', 'search'], {
      server => 'linktest1',
      linked_id => $current->o ('i1'),
      linked_key => rand,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
    return $current->post (['link', 'search'], {
      server => 'linktest1',
      linked_key => rand,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
    return $current->post (['link', 'search'], {
      server => 'linktest2',
      linked_id => $current->o ('i1'),
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
  });
} n => 22, name => '/link/search';

Test {
  my $current = shift;
  $current->generate_id (i1 => {});
  return $current->create (
    [a1 => account => {}],
    [a2 => account => {}],
    [a3 => account => {}],
    [a4 => account => {}],
    [a5 => account => {}],
  )->then (sub {
    return promised_for {
      my $account = shift;
      return $current->post (['link', 'add'], {
        server => 'linktest1',
        sk => $current->o ($account)->{session}->{sk},
        #sk_context is implied
        linked_id => $current->o ('i1'),
      });
    } ['a1', 'a2', 'a3', 'a4', 'a5'];
  })->then (sub {
    return $current->pages_ok ([['link', 'search'], {
      server => 'linktest1',
      linked_id => $current->o ('i1'),
    }] => ['a1', 'a2', 'a3', 'a4', 'a5'], 'account_id');
  });
} n => 1, name => '/link/search paging';

RUN;

=head1 LICENSE

Copyright 2021 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
