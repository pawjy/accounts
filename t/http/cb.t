use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->client->request (path => ['cb'])->then (sub {
    my $res = $_[0];
    test {
      is $res->status, 405;
    } $current->c;
  });
} n => 1, name => '/cb GET';

Test {
  my $current = shift;
  return $current->client->request (path => ['cb'], method => 'POST')->then (sub {
    my $res = $_[0];
    test {
      is $res->status, 401;
    } $current->c;
  });
} n => 1, name => '/cb no auth';

Test {
  my $current = shift;
  return $current->post (['cb'], {})->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad session';
      ok ! $result->{json}->{need_reload};
      is $result->{json}->{error_for_dev}, '/cb bad session';
    } $current->c;
  });
} n => 4, name => '/cb bad session';

Test {
  my $current = shift;
  return $current->create_session (1)->then (sub {
    return $current->post (['cb'], {}, session => 1);
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad callback call';
      ok ! $result->{json}->{need_reload};
    } $current->c;
  });
} n => 3, name => '/cb not in flow';

Test {
  my $current = shift;
  return $current->post (['cb'], {
    sk => rand,
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad session';
      ok ! $result->{json}->{need_reload};
      is $result->{json}->{error_for_dev}, '/cb bad session';
    } $current->c;
  });
} n => 4, name => '/cb bad session, bad sk only';

Test {
  my $current = shift;
  return $current->post (['cb'], {
    sk => rand,
    state => rand,
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad session';
      ok ! $result->{json}->{need_reload};
      is $result->{json}->{error_for_dev}, '/cb bad session';
    } $current->c;
  });
} n => 4, name => '/cb bad session, bad sk and state';

Test {
  my $current = shift;
  return $current->post (['cb'], {
    sk => undef,
    state => rand,
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad session';
      ok $result->{json}->{need_reload};
      is $result->{json}->{error_for_dev}, '/cb bad session';
    } $current->c;
  });
} n => 4, name => '/cb state only';

Test {
  my $current = shift;
  return $current->post (['cb'], {
    sk => undef,
    state => rand,
    reloaded => 1,
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad session';
      ok ! $result->{json}->{need_reload};
      is $result->{json}->{error_for_dev}, '/cb bad session';
    } $current->c;
  });
} n => 4, name => '/cb state only, reloaded';

Test {
  my $current = shift;
  return $current->post (['cb'], {
    sk => rand,
    state => rand,
    reloaded => 1,
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad session';
      ok ! $result->{json}->{need_reload};
      is $result->{json}->{error_for_dev}, '/cb bad session';
    } $current->c;
  });
} n => 4, name => '/cb bad session, reloaded';

RUN;

=head1 LICENSE

Copyright 2015-2021 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
