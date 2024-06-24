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
  });
} n => 7, name => 'by account ID';

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
  });
} n => 6, name => 'by session';

RUN;

=head1 LICENSE

Copyright 2015-2024 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
