use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->client->request (path => ['login'])->then (sub {
    my $res = $_[0];
    test {
      is $res->status, 405;
    } $current->c;
  });
} n => 1, name => '/login GET';

Test {
  my $current = shift;
  return $current->client->request (path => ['login'], method => 'POST')->then (sub {
    my $res = $_[0];
    test {
      is $res->status, 401;
    } $current->c;
  });
} n => 1, name => '/login no auth';

Test {
  my $current = shift;
  return $current->post (['login'], {})->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad session';
    } $current->c;
  });
} n => 2, name => '/login bad session';

Test {
  my $current = shift;
  return $current->post (['session'], {})->then (sub {
    die $_[0]->{res} unless $_[0]->{status} == 200;
    my $session = $_[0]->{json};
    return $current->post (['login'], {
      sk => $session->{sk},
      sk_context => 'not-tests',
      server => 'oauth1server',
      callback_url => 'http://haoa/',
    })->then (sub { test { ok 0 } $current->c }, sub {
      my $result = $_[0];
      test {
        is $result->{status}, 400;
        is $result->{json}->{reason}, 'Bad session';
      } $current->c;
    });
  });
} n => 2, name => '/login bad sk_context';

Test {
  my $current = shift;
  return $current->create_session (1)->then (sub {
    return $current->post (['login'], {
      server => 'xaa',
      callback_url => 'http://haoa/',
    }, session => 1)->then (sub { test { ok 0 } $current->c }, sub {
      my $result = $_[0];
      test {
        is $result->{status}, 400;
        is $result->{json}->{reason}, 'Bad |server|';
      } $current->c;
    });
  });
} n => 2, name => '/login bad server';

Test {
  my $current = shift;
  return $current->create_session (1)->then (sub {
    return $current->post (['login'], {
      server => 'oauth1server',
      callback_url => 'http://haoa/',
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $auth = $current->{servers_data}->{oauth1_auth_url};
      like $result->{json}->{authorization_url}, qr{^\Q$auth\E\?oauth_token=.+$};
    } $current->c;
  });
} n => 2, name => '/login';

Test {
  my $current = shift;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {}, session => 1);
  })->then (sub {
    return $current->post (['login'], {
      server => 'oauth2server',
      callback_url => 'http://haoa/',
    }, session => 1);
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Account-associated session';
    } $current->c;
  });
} n => 2, name => '/login with logined account';

RUN;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
