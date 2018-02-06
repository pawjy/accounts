use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib')
use Tests;

Test {
  my $current = shift;
  my $k1 = rand;
  my $k2 = rand;
  my $key;
  return $current->create_account (a1 => {})->then (sub {
    return $current->are_errors (
      [['invite', 'create'], {
        context_key => $k1,
        invitation_context_key => $k2,
        account_id => $current->o ('a1')->{account_id},
      }],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {bearer => rand, status => 401},
        {params => {}, status => 400},
        {params => {
          context_key => $k1,
          invitation_context_key => $k2,
          account_id => undef,
        }, status => 400},
        {params => {
          context_key => $k1,
          invitation_context_key => $k2,
          account_id => 0,
        }, status => 400},
        {params => {
          context_key => undef,
          invitation_context_key => $k2,
          account_id => $current->o ('a1')->{account_id},
        }, status => 400},
        {params => {
          context_key => $k1,
          invitation_context_key => undef,
          account_id => $current->o ('a1')->{account_id},
        }, status => 400},
      ],
    );
  })->then (sub {
    return $current->post (['invite', 'create'], {
      context_key => $k1,
      invitation_context_key => $k2,
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{context_key}, $k1;
      is $result->{json}->{invitation_context_key}, $k2;
      ok $key = $result->{json}->{invitation_key};
    } $current->c;
    return $current->post (['invite', 'list'], {
      context_key => $k1,
      invitation_context_key => $k2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $inv = $result->{json}->{invitations}->{$key};
      is $inv->{invitation_key}, $key;
      is $inv->{author_account_id}, $current->o ('a1')->{account_id};
      is $inv->{invitation_data}, undef;
      is $inv->{target_account_id}, 0;
      ok $inv->{created};
      ok $inv->{expires} > $inv->{created};
      is $inv->{user_account_id}, 0;
      is $inv->{used_data}, undef;
      is $inv->{used}, 0;
      like $result->{res}->body_bytes, qr{"author_account_id"\s*:\s*"};
      like $result->{res}->body_bytes, qr{"target_account_id"\s*:\s*"};
      like $result->{res}->body_bytes, qr{"user_account_id"\s*:\s*"};
    } $current->c;
  });
} n => 17, name => '/invite/create';

Test {
  my $current = shift;
  my $k1 = rand;
  my $k2 = rand;
  my $key;
  return $current->create_account (a1 => {})->then (sub {
    return $current->post (['invite', 'create'], {
      context_key => $k1,
      invitation_context_key => $k2,
      account_id => $current->o ('a1')->{account_id},
      data => (perl2json_chars {hoge => [134, {a => ''}]}),
      target_account_id => 54234553333,
      expires => 43534456666,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{context_key}, $k1;
      is $result->{json}->{invitation_context_key}, $k2;
      ok $key = $result->{json}->{invitation_key};
    } $current->c;
    return $current->post (['invite', 'list'], {
      context_key => $k1,
      invitation_context_key => $k2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $inv = $result->{json}->{invitations}->{$key};
      is $inv->{invitation_key}, $key;
      is $inv->{author_account_id}, $current->o ('a1')->{account_id};
      is $inv->{invitation_data}->{hoge}->[0], 134;
      is $inv->{invitation_data}->{hoge}->[1]->{a}, '';
      is $inv->{target_account_id}, 54234553333;
      ok $inv->{created};
      is $inv->{expires}, 43534456666;
      is $inv->{user_account_id}, 0;
      is $inv->{used_data}, undef;
      is $inv->{used}, 0;
      like $result->{res}->body_bytes, qr{"author_account_id"\s*:\s*"};
      like $result->{res}->body_bytes, qr{"target_account_id"\s*:\s*"};
      like $result->{res}->body_bytes, qr{"user_account_id"\s*:\s*"};
    } $current->c;
  });
} n => 17, name => '/invite/create';

RUN;

=head1 LICENSE

Copyright 2017-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
