use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return Promise->resolve->then (sub {
    return $current->post (['profiles'], {
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is 0+keys %{$res->{json}->{accounts}}, 0;
    } $current->c;
  });
} n => 1, name => '/profiles without account_id';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->are_errors (
      [['profiles'], {
        account_id => $current->o ('a1')->{account_id},
      }],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {bearer => rand, status => 401},
      ],
    );
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $res = $_[0];
    test {
      my $data = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
      is $data->{account_id}, $current->o ('a1')->{account_id};
      is $data->{name}, $current->o ('n1');
      like $res->{res}->body_bytes, qr{"account_id"\s*:\s*"};
    } $current->c;
  });
} n => 4, name => '/profiles with account_id, matched';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->create_account (a2 => {
      name => $current->generate_text ('n2'),
    });
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => [$current->o ('a1')->{account_id},
                     $current->o ('a2')->{account_id},
                     $current->generate_id ('id1')],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      my $data = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
      is $data->{account_id}, $current->o ('a1')->{account_id};
      is $data->{name}, $current->o ('n1');
      my $data2 = $res->{json}->{accounts}->{$current->o ('a2')->{account_id}};
      is $data2->{account_id}, $current->o ('a2')->{account_id};
      is $data2->{name}, $current->o ('n2');
      ok ! $res->{json}->{accounts}->{$current->o ('id1')};
      like $res->{res}->body_bytes, qr{"account_id"\s*:\s*"};
    } $current->c;
  });
} n => 6, name => '/profiles with account_id, multiple';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
    user_status => 2,
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => $current->o ('a1'),
      user_status => [1, 3],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{json}->{accounts}->{$current->o ('a1')->{account_id}}, undef;
    } $current->c;
  });
} n => 1, name => '/profiles with account_id, user_status filtered';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
    admin_status => 2,
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => $current->o ('a1'),
      admin_status => [1, 3],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{json}->{accounts}->{$current->o ('a1')->{account_id}}, undef;
    } $current->c;
  });
} n => 1, name => '/profiles with account_id, admin_status filtered';

RUN;

=head1 LICENSE

Copyright 2015-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
