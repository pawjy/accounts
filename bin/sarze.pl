use strict;
use warnings;
use Path::Tiny;
use Promise;
use Sarze;

my $host = shift;
my $port = shift or die "Usage: $0 host port";

Sarze->run (
  hostports => [
    [$host, $port],
  ],
  psgi_file_name => path (__FILE__)->parent->child ('server.psgi'),
  max_request_body_length => 100*1024*1024,
)->to_cv->recv;

=head1 LICENSE

Copyright 2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
