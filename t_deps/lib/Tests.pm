package Tests;
use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/modules/*/lib');
use Promise;
use Promised::Flow;
use JSON::PS;
use Web::URL;
use Web::URL::Encoding;
use Test::X1;
use Test::More;

use AccSS;
use Tests::Current;

our @EXPORT = (@JSON::PS::EXPORT,
               @Web::URL::Encoding::EXPORT,
               @Promised::Flow::EXPORT,
               @Test::X1::EXPORT,
               grep { not /^\$/ } @Test::More::EXPORT);

sub import ($;@) {
  my $from_class = shift;
  my ($to_class, $file, $line) = caller;
  no strict 'refs';
  for (@_ ? @_ : @{$from_class . '::EXPORT'}) {
    my $code = $from_class->can ($_)
        or die qq{"$_" is not exported by the $from_class module at $file line $line};
    *{$to_class . '::' . $_} = $code;
  }
} # import

our $ServersData;
push @EXPORT, qw(Test);
sub Test (&;%) {
  my $code = shift;
  test (sub {
    my $current = bless {
      context => $_[0], servers_data => $ServersData,
    }, 'Tests::Current';
    return Promise->resolve ($current)->then ($code)->catch (sub {
      my $error = $_[0];
      test {
        ok 0, 'No exception';
        is $error, undef, 'No exception';
      } $current->c;
    })->finally (sub {
      $current->done;
    });
  }, @_);
} # Test

push @EXPORT, qw(RUN);
sub RUN () {
  note "Servers...";
  my $ac = AbortController->new;
  my $v = AccSS->run (
    signal => $ac->signal,
    mysqld_database_name_suffix => '_test',
  )->to_cv->recv;

  note "Tests...";
  local $ServersData = $v->{data};
  run_tests;

  note "Done";
  $ac->abort;
  $v->{done}->to_cv->recv;
} # RUN

1;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You does not have received a copy of the GNU Affero General Public
License along with this program, see <http://www.gnu.org/licenses/>.

=cut
