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
  return $current->post (['cb'], {})->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad session';
    } $current->c;
  });
} n => 2, name => '/cb bad session';

Test {
  my $current = shift;
  return $current->create_session (1)->then (sub {
    return $current->post (['cb'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad callback call';
    } $current->c;
  });
} n => 2, name => '/cb not in flow';

RUN;

=head1 LICENSE

Copyright 2015-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
