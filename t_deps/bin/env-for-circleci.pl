use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/modules/*/lib');
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use AbortController;
use AccSS;

my $RootPath = path (__FILE__)->parent->parent->parent;

my $NeedBrowser = $ENV{IS_BROWSER_TEST};
my $ac = AbortController->new;
AccSS->run (
  app_docker_image => $ENV{TEST_APP_DOCKER_IMAGE},
  mysqld_database_name_suffix => '_test',
  docker_net_host => 1,
  no_set_uid => 1,
  need_browser => $NeedBrowser,
  browser_type => $ENV{TEST_WD_BROWSER}, # or undef
  docker_net_host => $ENV{CIRCLECI},
  write_ss_env => 1,
  signal => $ac->signal,
)->then (sub {
  warn "$$: Test env is ready\n";

  return $_[0]->{done};
})->to_cv->recv; # or croak

=head1 LICENSE

Copyright 2018-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
