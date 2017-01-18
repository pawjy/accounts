use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

my $wait = web_server;

Test {
  my $current = shift;
  return $current->client->request (path => ['create'])->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 405;
    } $current->c;
  });
} wait => $wait, n => 1, name => '/create GET';

Test {
  my $current = shift;
  return $current->client->request (path => ['create'], method => 'POST')->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 401;
    } $current->c;
  });
} wait => $wait, n => 1, name => '/create no auth';

Test {
  my $current = shift;
  return $current->post (['create'], {
    sk_context => undef,
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
    } $current->c;
  });
} wait => $wait, n => 1, name => '/create no session';

Test {
  my $current = shift;
  return $current->post (['create'], {})->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
    } $current->c;
  });
} wait => $wait, n => 1, name => '/create no session';

Test {
  my $current = shift;
  my $account_id;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      ok $account_id = $result->{json}->{account_id};
    } $current->c;
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $account_id;
      is $result->{json}->{name}, $account_id;
      is $result->{json}->{user_status}, 1;
      is $result->{json}->{admin_status}, 1;
      is $result->{json}->{terms_version}, 0;
    } $current->c;
  });
} wait => $wait, n => 8, name => '/create has anon session';

Test {
  my $current = shift;
  my $account_id;
  return $current->post (['create'], {
    sk => 'gfaeaaaaa',
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad session';
    } $current->c;
  });
} wait => $wait, n => 2, name => '/create bad session';

Test {
  my $current = shift;
  my $account_id;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {
      name => "\x{65000}",
      user_status => 2,
      admin_status => 6,
      terms_version => 5244,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      ok $account_id = $result->{json}->{account_id};
    } $current->c;
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $account_id;
      is $result->{json}->{name}, "\x{65000}";
      is $result->{json}->{user_status}, 2;
      is $result->{json}->{admin_status}, 6;
      is $result->{json}->{terms_version}, 255;
    } $current->c;
  });
} wait => $wait, n => 8, name => '/create with options';

Test {
  my $current = shift;
  my $account_id;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {
      name => "hoge",
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      ok $account_id = $result->{json}->{account_id};
    } $current->c;
    return $current->post (['create'], {
      name => "\x{65000}",
      user_status => 2,
      admin_status => 6,
      terms_version => 5244,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Account-associated session';
    } $current->c;
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $account_id;
      is $result->{json}->{name}, "hoge";
    } $current->c;
  });
} wait => $wait, n => 6, name => '/create with associated session';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2015-2016 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
