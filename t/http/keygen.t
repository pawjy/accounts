use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {account => 1}],
    [s2 => session => {}],
  )->then (sub {
    return $current->are_errors (
      [['keygen'], {
        server => 'ssh',
      }, session => 's1'],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {session => undef, status => 400, reason => 'Not a login user'},
        {session => 's2', status => 400, reason => 'Not a login user'},
        {params => {server => ''}, status => 400, reason => 'Bad |server|'},
      ],
    );
  })->then (sub {
    return $current->post (['keygen'], {
      server => 'ssh',
      source_ipaddr => $current->generate_key (k1 => {}),
      source_ua => $current->generate_key (k2 => {}),
      source_data => perl2json_chars ({foo => $current->generate_text (t1 => {})}),
    }, session => 's1');
  })->then (sub {
    return $current->post (['token'], {
      server => 'ssh',
    }, session => 's1');
  })->then (sub {
    my $json = $_[0]->{json};
    $current->set_o (token1 => $json);
    test {
      like $json->{access_token}->[0], qr{^ssh-rsa \S+};
      unlike $json->{access_token}->[0], qr{PRIVATE KEY};
      like $json->{access_token}->[1], qr{PRIVATE KEY};
    } $current->c;
  })->then (sub {
    return $current->post (['keygen'], {
      server => 'ssh',
    }, session => 's1'); # second
  })->then (sub {
    return $current->post (['token'], {
      server => 'ssh',
    }, session => 's1');
  })->then (sub {
    my $json = $_[0]->{json};
    test {
      like $json->{access_token}->[0], qr{^ssh-rsa \S+};
      unlike $json->{access_token}->[0], qr{PRIVATE KEY};
      like $json->{access_token}->[1], qr{PRIVATE KEY};
      isnt $json->{access_token}->[0], $current->o ('token1')->{access_token}->[0];
      isnt $json->{access_token}->[1], $current->o ('token1')->{access_token}->[1];
    } $current->c;
    return $current->post (['log', 'get'], {
      account_id => $current->o ('s1')->{account}->{account_id},
      action => 'link',
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 2;
      my $item = $result->{json}->{items}->[1];
      ok $item->{log_id};
      is $item->{account_id}, $current->o ('s1')->{account}->{account_id};
      is $item->{operator_account_id}, $current->o ('s1')->{account}->{account_id};
      ok $item->{timestamp};
      ok $item->{timestamp} < time;
      is $item->{action}, 'link';
      is $item->{ua}, $current->o ('k2');
      is $item->{ipaddr}, $current->o ('k1');
      ok $item->{data};
      is $item->{data}->{source_operation}, 'keygen';
      is $item->{data}->{key_type}, 'rsa';
      is $item->{data}->{source_data}->{foo}, $current->o ('t1');
      like $result->{res}->body_bytes, qr{"account_link_id":"};
      ok $item->{data}->{account_link_id};
    } $current->c;
  });
} n => 24, name => '/keygen has account session', timeout => 60;

RUN;

=head1 LICENSE

Copyright 2015-2023 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
