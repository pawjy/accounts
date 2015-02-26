# -*- perl -*-
use strict;
use warnings;
use Accounts::Web;

$ENV{LANG} = 'C';
$ENV{TZ} = 'UTC';

my $config = {
  #XXX
  #web_origin => 'http://localhost:5000',
};

return Accounts::Web->psgi_app ($config);

=head1 LICENSE

Copyright 2007-2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
