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
    return $current->post (['agree'], {
      version => 10,
    }, session => 's1');
  })->then (sub {
    return $current->are_errors (
      [['agree'], {version => 11}],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {session => undef, status => 400, reason => 'Not a login user'},
        {session => 's2', status => 400, reason => 'Not a login user'},
      ],
    );
  })->then (sub {
    return $current->post (['info'], {}, session => 's2');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{terms_version}, undef;
    } $current->c, name => 'no account session unchanged';
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{terms_version}, 10;
    } $current->c;
    return $current->post (['agree'], {
      version => 12,
    }, session => 's1');
  })->then (sub {
    return $current->post (['agree'], {
    }, session => 's1'); # nop
  })->then (sub {
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{terms_version}, 12;
    } $current->c;
    return $current->post (['agree'], {
      version => 10,
    }, session => 's1');
  })->then (sub {
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{terms_version}, 12;
    } $current->c;
    return $current->post (['agree'], {
      version => 3,
    }, session => 's1');
  })->then (sub {
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{terms_version}, 12;
    } $current->c;
    return $current->post (['agree'], {
      version => 255,
    }, session => 's1');
  })->then (sub {
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{terms_version}, 255;
    } $current->c;
    return $current->post (['agree'], {
      version => 256,
    }, session => 's1');
  })->then (sub {
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{terms_version}, 255;
    } $current->c;
    return $current->post (['agree'], {
      version => 0,
      downgrade => 1,
    }, session => 's1');
  })->then (sub {
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{terms_version}, 0;
    } $current->c;
  });
} n => 9, name => '/agree updated';

RUN;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
