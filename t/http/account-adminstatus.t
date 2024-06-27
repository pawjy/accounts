use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create (
    [a1 => account => {
    }],
    [a2 => account => {
    }],
    [s3 => session => {}],
  )->then (sub {
    return $current->are_errors (
      [['account', 'admin_status'], {
        account_id => $current->o ('a2')->{account_id},
        admin_status => 6,
      }],
      [
        {params => {account_id => undef, admin_status => 6},
         status => 400, name => 'No |account_id|'},
        {params => {account_id => 'abd', admin_status => 6},
         status => 400, name => 'Bad |account_id|'},
        {params => {account_id => 12515333, admin_status => 6},
         status => 400, name => 'Not found |account_id|'},
        {params => {admin_status => 6, sk_context => rand, sk => rand},
         status => 400, name => 'Bad session'},
        {params => {admin_status => 6}, session => 's3',
         status => 400, name => 'Bad session'},
        {params => {
          account_id => $current->o ('a2')->{account_id},
          admin_status => 0,
        }, status => 400, name => 'Bad status'},
        {params => {
          account_id => $current->o ('a2')->{account_id},
          user_status => 4,
        }, status => 400, name => 'Bad status'},
      ],
    );
  })->then (sub {
    return $current->post (['account', 'admin_status'], {
      account_id => $current->o ('a1')->{account_id},
      admin_status => 3,
      source_ipaddr => $current->generate_key (k1 => {}),
      source_ua => $current->generate_key (k2 => {}),
    });
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => [
        $current->o ('a1')->{account_id},
        $current->o ('a2')->{account_id},
      ],
      with_statuses => 1,
    });
  })->then (sub {
    my $res = $_[0];
    test {
      {
        my $acc = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
        is $acc->{admin_status}, 3;
        is $acc->{user_status}, 1;
        is $acc->{terms_version}, 0;
      }
      {
        my $acc = $res->{json}->{accounts}->{$current->o ('a2')->{account_id}};
        is $acc->{admin_status}, 1;
        is $acc->{user_status}, 1;
        is $acc->{terms_version}, 0;
      }
    } $current->c;
    return $current->post (['log', 'get'], {
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      $result->{json}->{items} = [grep { $_->{action} eq 'status' } @{$result->{json}->{items}}];
      is 0+@{$result->{json}->{items}}, 1;
      {
        my $item = $result->{json}->{items}->[0];
        ok $item->{log_id};
        is $item->{account_id}, $current->o ('a1')->{account_id};
        is $item->{operator_account_id}, $current->o ('a1')->{account_id};
        ok $item->{timestamp};
        ok $item->{timestamp} < time;
        is $item->{action}, 'status';
        is $item->{ua}, $current->o ('k2');
        is $item->{ipaddr}, $current->o ('k1');
        ok $item->{data};
        is $item->{data}->{source_operation}, 'admin_status';
        is $item->{data}->{user_status}, undef;
        is $item->{data}->{admin_status}, 3;
      }
    } $current->c;
  });
} n => 20, name => 'by account ID';

Test {
  my $current = shift;
  return $current->create (
    [a1 => account => {
    }],
    [a2 => account => {
    }],
  )->then (sub {
    return $current->post (['account', 'admin_status'], {
      admin_status => 3,
      source_ipaddr => $current->generate_key (k1 => {}),
      source_ua => $current->generate_key (k2 => {}),
    }, account => 'a1');
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => [
        $current->o ('a1')->{account_id},
        $current->o ('a2')->{account_id},
      ],
      with_statuses => 1,
    });
  })->then (sub {
    my $res = $_[0];
    test {
      {
        my $acc = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
        is $acc->{admin_status}, 3;
        is $acc->{user_status}, 1;
        is $acc->{terms_version}, 0;
      }
      {
        my $acc = $res->{json}->{accounts}->{$current->o ('a2')->{account_id}};
        is $acc->{admin_status}, 1;
        is $acc->{user_status}, 1;
        is $acc->{terms_version}, 0;
      }
    } $current->c;
    return $current->post (['log', 'get'], {
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      $result->{json}->{items} = [grep { $_->{action} eq 'status' } @{$result->{json}->{items}}];
      is 0+@{$result->{json}->{items}}, 1;
      {
        my $item = $result->{json}->{items}->[0];
        ok $item->{log_id};
        is $item->{account_id}, $current->o ('a1')->{account_id};
        is $item->{operator_account_id}, $current->o ('a1')->{account_id};
        ok $item->{timestamp};
        ok $item->{timestamp} < time;
        is $item->{action}, 'status';
        is $item->{ua}, $current->o ('k2');
        is $item->{ipaddr}, $current->o ('k1');
        ok $item->{data};
        is $item->{data}->{source_operation}, 'admin_status';
        is $item->{data}->{user_status}, undef;
        is $item->{data}->{admin_status}, 3;
      }
    } $current->c;
  });
} n => 19, name => 'by session';

Test {
  my $current = shift;
  return $current->create (
    [a1 => account => {
    }],
  )->then (sub {
    return $current->post (['account', 'admin_status'], {
      admin_status => 3,
      source_ipaddr => $current->generate_key (k1 => {}),
      source_ua => $current->generate_key (k2 => {}),
      source_data => perl2json_chars ({foo => $current->generate_key (k3 => {})}),
      operator_account_id => $current->generate_id (k4 => {}),
    }, account => 'a1');
  })->then (sub {
    return $current->post (['log', 'get'], {
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      $result->{json}->{items} = [grep { $_->{action} eq 'status' } @{$result->{json}->{items}}];
      is 0+@{$result->{json}->{items}}, 1;
      {
        my $item = $result->{json}->{items}->[0];
        ok $item->{log_id};
        is $item->{account_id}, $current->o ('a1')->{account_id};
        is $item->{operator_account_id}, $current->o ('k4');
        ok $item->{timestamp};
        ok $item->{timestamp} < time;
        is $item->{action}, 'status';
        is $item->{ua}, $current->o ('k2');
        is $item->{ipaddr}, $current->o ('k1');
        ok $item->{data};
        is $item->{data}->{source_operation}, 'admin_status';
        is $item->{data}->{user_status}, undef;
        is $item->{data}->{admin_status}, 3;
        is $item->{data}->{source_data}->{foo}, $current->o ('k3');
      }
    } $current->c;
  });
} n => 14, name => 'logs';

RUN;

=head1 LICENSE

Copyright 2015-2024 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
