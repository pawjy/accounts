# -*- perl -*-
use strict;
use warnings;
use AnyEvent;

use Accounts::Config;
use Accounts::Web;
use WorkerState;

$ENV{LANG} = 'C';
$ENV{TZ} = 'UTC';

my $config_file_name = $ENV{APP_CONFIG}
    // die "Usage: APP_CONFIG=config.json ./plackup bin/server.psgi";
my $cv = AE::cv;
Accounts::Config->from_file_name ($config_file_name)->then (sub {
  $cv->send ($_[0]);
}, sub {
  $cv->croak ($_[0]);
});
my $config = $cv->recv;

return Accounts::Web->psgi_app ($config);

=head1 LICENSE

Copyright 2007-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
