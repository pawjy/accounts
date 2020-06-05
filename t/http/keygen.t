use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {account => 1}],
    [s2 => session => {}],
  )->then (sub {
    return $current->are_errors (
      [['keygen'], {
        server => 'ssh',
      }, session => 's1'],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {session => undef, status => 400, reason => 'Not a login user'},
        {session => 's2', status => 400, reason => 'Not a login user'},
        {params => {server => ''}, status => 400, reason => 'Bad |server|'},
      ],
    );
  })->then (sub {
    return $current->post (['keygen'], {
      server => 'ssh',
    }, session => 's1');
  })->then (sub {
    return $current->post (['token'], {
      server => 'ssh',
    }, session => 's1');
  })->then (sub {
    my $json = $_[0]->{json};
    $current->set_o (token1 => $json);
    test {
      like $json->{access_token}->[0], qr{^ssh-rsa \S+};
      unlike $json->{access_token}->[0], qr{PRIVATE KEY};
      like $json->{access_token}->[1], qr{PRIVATE KEY};
    } $current->c;
  })->then (sub {
    return $current->post (['keygen'], {
      server => 'ssh',
    }, session => 's1'); # second
  })->then (sub {
    return $current->post (['token'], {
      server => 'ssh',
    }, session => 's1');
  })->then (sub {
    my $json = $_[0]->{json};
    test {
      like $json->{access_token}->[0], qr{^ssh-rsa \S+};
      unlike $json->{access_token}->[0], qr{PRIVATE KEY};
      like $json->{access_token}->[1], qr{PRIVATE KEY};
      isnt $json->{access_token}->[0], $current->o ('token1')->{access_token}->[0];
      isnt $json->{access_token}->[1], $current->o ('token1')->{access_token}->[1];
    } $current->c;
  });
} n => 9, name => '/keygen has account session', timeout => 60;

RUN;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
