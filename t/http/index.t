use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->client->request (
    path => [],
  )->then (sub {
    my $res = $_[0];
    test {
      is $res->status, 404;
    } $current->c;
  });
} n => 1, name => '/index GET';

Test {
  my $current = shift;
  return $current->client->request (path => ['robots.txt'])->then (sub {
    my $res = $_[0];
    test {
      is $res->code, 200;
      is $res->content, qq{User-agent: *\nDisallow: /};
    } $current->c;
  });
} n => 2, name => '/robots.txt GET';

RUN;

=head1 LICENSE

Copyright 2015-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
