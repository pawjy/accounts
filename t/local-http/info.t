use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

my $wait = web_server;

Test {
  my $current = shift;
  my $name = "\x{53533}" . rand;
  return $current->create_account (a1 => {name => $name})->then (sub {
    return $current->are_errors (
      [['info'], {
        sk => $current->o ('a1')->{session}->{sk},
      }],
      [
        {method => 'GET', status => 405, name => 'Bad method'},
        {bearer => undef, status => 401, name => 'No bearer'},
        {bearer => rand, status => 401, name => 'Bad bearer'},
      ],
    );
  })->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('a1')->{session}->{sk},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $current->o ('a1')->{account_id};
      like $result->{res}->body_bytes, qr{"account_id"\s*:\s*"};
      is $result->{json}->{name}, $name;
    } $current->c;
  });
} wait => $wait, n => 5, name => '/info with accounted session';

Test {
  my $current = shift;
  return $current->create_session (s1 => {})->then (sub {
    return $current->post (['info'], {});
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, undef;
      is $result->{json}->{name}, undef;
    } $current->c;
  });
} wait => $wait, n => 2, name => '/info no session';

Test {
  my $current = shift;
  return $current->create_session (s1 => {})->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('s1')->{sk},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, undef;
      is $result->{json}->{name}, undef;
    } $current->c;
  });
} wait => $wait, n => 3, name => '/info has anon session';

Test {
  my $current = shift;
  return $current->create_session (s1 => {})->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('s1')->{sk},
      with_linked => ['id', 'realname', 'icon_url'],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, undef;
      is $result->{json}->{name}, undef;
      is $result->{linked}, undef;
    } $current->c;
  });
} wait => $wait, n => 4, name => '/info with linked (no match)';

Test {
  my $current = shift;
  return $current->post (['info'], {sk => 'gfaeaaaaa'})->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, undef;
      is $result->{json}->{name}, undef;
    } $current->c;
  });
} wait => $wait, n => 3, name => '/info bad session';

Test {
  my $current = shift;
  my $v1 = "\x{53533}" . rand;
  my $v2 = rand;
  return $current->create_account (a1 => {data => {
    name => $v1,
    hoge => $v2,
  }})->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('a1')->{session}->{sk},
      with_data => ['name', 'hoge', 'foo'],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{data}->{name}, $v1;
      is $result->{json}->{data}->{hoge}, $v2;
      is $result->{json}->{data}->{foo}, undef;
    } $current->c;
  });
} wait => $wait, n => 4, name => '/info with data';

Test {
  my $current = shift;
  return $current->create_group (g1 => {})->then (sub {
    return $current->post (['info'], {
      sk => undef,
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, undef;
      is $result->{json}->{group_membership}, undef;
      is $result->{json}->{group}->{group_id}, $current->o ('g1')->{group_id};
      like $result->{res}->body_bytes, qr{"group_id"\s*:\s*"};
      is $result->{json}->{group}->{owner_status}, 1;
      is $result->{json}->{group}->{admin_status}, 1;
      ok $result->{json}->{group}->{created};
      ok $result->{json}->{group}->{updated};
    } $current->c;
  });
} wait => $wait, n => 9, name => '/info no sk, group_id';

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->create_group (g1 => {members => [{
      account_id => $current->o ('a1')->{account_id},
      user_status => 3,
      owner_status => 6,
      member_type => 9,
    }]});
  })->then (sub {
    return $current->post (['info'], {
      sk => $current->o ('a1')->{session}->{sk},
      context_key => $current->o ('g1')->{context_key},
      group_id => $current->o ('g1')->{group_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $current->o ('a1')->{account_id};
      is $result->{json}->{group_membership}->{user_status}, 3;
      is $result->{json}->{group_membership}->{owner_status}, 6;
      is $result->{json}->{group_membership}->{member_type}, 9;
      is $result->{json}->{group}->{group_id}, $current->o ('g1')->{group_id};
      like $result->{res}->body_bytes, qr{"group_id"\s*:\s*"};
      is $result->{json}->{group}->{owner_status}, 1;
      is $result->{json}->{group}->{admin_status}, 1;
      ok $result->{json}->{group}->{created};
      ok $result->{json}->{group}->{updated};
    } $current->c;
  });
} wait => $wait, n => 11, name => '/info with sk, group_id';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2015-2017 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
