use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create (
  )->then (sub {
    return $current->are_errors (
      [['log', 'get'], {log_id => 124}],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {params => {}, status => 400},
      ],
    );
  })->then (sub {
    return $current->post (['log', 'get'], {log_id => 124});
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
  });
} n => 2, name => 'empty';

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {}],
  )->then (sub {
    return $current->post (['create'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    $current->set_o (a1 => $result->{json});
    return $current->post (['log', 'get'], {
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      like $result->{res}->body_bytes, qr{"account_id":"};
      like $result->{res}->body_bytes, qr{"log_id":"};
      like $result->{res}->body_bytes, qr{"operator_account_id":"};
    } $current->c;
    return $current->post (['log', 'get'], {
      operator_account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      $current->set_o (log1 => $result->{json}->{items}->[0]);
    } $current->c;
    return $current->post (['log', 'get'], {
      log_id => $current->o ('log1')->{log_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
    } $current->c;
  });
} n => 6, name => 'an item';

Test {
  my $current = shift;
  $current->generate_id (i1 => {});
  return $current->create (
    [s1 => session => {}],
    [s2 => session => {}],
    [s3 => session => {}],
    [s4 => session => {}],
    [s5 => session => {}],
  )->then (sub {
    $current->generate_key (k1 => {});
    return promised_for {
      my $session = shift;
      return $current->post (['create'], {
        source_ipaddr => $current->o ('k1'),
      }, session => $session)->then (sub {
        $current->set_o ('a' . $session => $_[0]->{json});
      });
    } ['s1', 's2', 's3', 's4', 's5'];
  })->then (sub {
    return $current->pages_ok ([['log', 'get'], {
      ipaddr => $current->o ('k1'),
    }] => ['as1', 'as2', 'as3', 'as4', 'as5'], 'account_id');
  });
} n => 1, name => 'paging';

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {}],
  )->then (sub {
    return $current->post (['create'], {
      source_data => perl2json_chars ({
        foo => 123,
      }),
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    $current->set_o (a1 => $result->{json});
    return $current->post (['log', 'get'], {
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 1;
      is $result->{json}->{items}->[0]->{data}->{source_operation}, 'create';
      is $result->{json}->{items}->[0]->{data}->{source_data}->{foo}, 123;
    } $current->c;
  });
} n => 3, name => 'attached data';

RUN;

=head1 LICENSE

Copyright 2023 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
