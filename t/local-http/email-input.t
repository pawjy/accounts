use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {}],
  )->then (sub {
    return $current->are_errors (
      [['email', 'input'], {addr => q<foo@abc.test>}, session => 's1'],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {session => undef, status => 400, reason => 'Bad session'},
        {params => {}, status => 400, reason => 'Bad email address'},
        {params => {addr => q<@hoge>}, status => 400, reason => 'Bad email address'},
        {params => {addr => qq<\x{5000}\@hoge.test>}, status => 400, reason => 'Bad email address'},
      ],
    );
  })->then (sub {

    return $current->post (['email', 'input'], {
      addr => q<foo@hoge.test>,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      ok $result->{json}->{key};
      $current->set_o (key1 => $result->{json}->{key});
    } $current->c;
    return $current->post (['email', 'input'], {
      addr => q<foo@hoge.test>,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      ok $result->{json}->{key};
      isnt $result->{json}->{key}, $current->o ('key1');
    } $current->c;

    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email'],
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{links}}, 0;
    } $current->c, name => 'unchanged yet';
  });
} n => 5, name => '/email/input associated';

Test {
  my $current = shift;
  return $current->create (
    [u1 => account => {}],
  )->then (sub {
    return $current->post (['email', 'input'], {
      addr => q<foo@bar.test>,
    }, account => 'u1');
  })->then (sub {
    return $current->post (['email', 'verify'], {
      key => $_[0]->{json}->{key},
    }, account => 'u1');
  })->then (sub {

    return $current->post (['email', 'input'], {
      addr => q<foo@hoge.test>,
    }, account => 'u1');
  })->then (sub {
    my $result = $_[0];
    test {
      ok $result->{json}->{key};
    } $current->c;

    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email'],
    }, account => 'u1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{links}}, 1;
      my $actual = [sort { $a cmp $b } map { $_->{email} } values %{$result->{json}->{links}}];
      is $actual->[0], 'foo@bar.test';
    } $current->c, name => 'unchanged';
  });
} n => 3, name => '/email/input already associated';

RUN;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
