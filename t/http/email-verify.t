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
    return $current->post (['email', 'input'], {
      addr => q<foo@bar.test>,
    }, session => 's1');
  })->then (sub {
    $current->set_o (key1 => $_[0]->{json}->{key});

    return $current->are_errors (
      [['email', 'verify'], {
        key => $current->o ('key1'),
      }, session => 's1'],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {session => undef, status => 400, reason => 'Bad session'},
        {session => 's2', status => 400, reason => 'Not a login user'},
        {params => {}, status => 400, reason => 'Bad key'},
        {params => {key => rand}, status => 400, reason => 'Bad key'},
      ],
    );
  })->then (sub {
    return $current->post (['email', 'verify'], {
      key => $current->o ('key1'),
    }, session => 's1'); # done
  })->then (sub {
    return $current->post (['email', 'verify'], {
      key => $current->o ('key1'),
    }, session => 's1'); # second
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $err = $_[0];
    test {
      is $err->{status}, 400;
      is $err->{json}->{reason}, 'Bad key', 'Key can be used only once';
    } $current->c;
    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email'],
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{links}}, 1;
      my $link = [values %{$result->{json}->{links}}]->[0];
      is $link->{service_name}, 'email';
      ok $link->{id};
      is $link->{email}, q<foo@bar.test>;
      is $link->{key}, undef;
      is $link->{name}, undef;
      ok ! $result->{json}->{no_email};
    } $current->c;
  });
} n => 10, name => '/email/verify associated';

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {account => 1}],
  )->then (sub {
    return $current->post (['email', 'input'], {
      addr => q<foo@bar.test>,
    }, session => 's1');
  })->then (sub {
    $current->set_o (key1 => $_[0]->{json}->{key});
    return $current->post (['email', 'input'], {
      addr => q<baz@bar.test>,
    }, session => 's1');
  })->then (sub {
    $current->set_o (key2 => $_[0]->{json}->{key});
    return $current->post (['email', 'verify'], {
      key => $current->o ('key1'),
    }, session => 's1');
  })->then (sub {
    return $current->post (['email', 'verify'], {
      key => $current->o ('key2'),
    }, session => 's1');
  })->then (sub {
    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email'],
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{links}}, 2;
      my $actual = [sort { $a cmp $b } map { $_->{email} } values %{$result->{json}->{links}}];
      is $actual->[0], 'baz@bar.test';
      is $actual->[1], 'foo@bar.test';
    } $current->c;
  });
} n => 3, name => '/email/verify multiple association';

RUN;

=head1 LICENSE

Copyright 2015-2023 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
