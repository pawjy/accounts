use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Test::More;
use Test::X1;

my $wait = web_server;

test {
  my $c = shift;
  return GET ($c, q</email/input>)->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 405;
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/email/input GET';

test {
  my $c = shift;
  return POST ($c, q</email/input>, bad_bearer => 1)->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 401;
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/email/input POST bad bearer';

test {
  my $c = shift;
  return POST ($c, q</email/input>)->then (sub { test { ok 0 } $c }, sub {
    my $json = $_[0];
    test {
      is $json->{reason}, 'Bad email address';
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/email/input POST no args';

test {
  my $c = shift;
  return POST ($c, q</email/input>, params => {
    addr => q<@hoge>,
  })->then (sub { test { ok 0 } $c }, sub {
    my $json = $_[0];
    test {
      is $json->{reason}, 'Bad email address';
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/email/input POST bad |addr|';

test {
  my $c = shift;
  return POST ($c, q</email/input>, params => {
    addr => qq<\x{5000}\@hoge.test>,
  })->then (sub { test { ok 0 } $c }, sub {
    my $json = $_[0];
    test {
      is $json->{reason}, 'Bad email address';
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/email/input POST bad |addr|';

test {
  my $c = shift;
  return POST ($c, q</email/input>, params => {
    addr => q<foo@hoge.test>,
  })->then (sub { test { ok 0 } $c }, sub {
    my $json = $_[0];
    test {
      is $json->{reason}, 'Bad session';
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/email/input POST bad session';

test {
  my $c = shift;
  return session ($c)->then (sub {
    my $session = $_[0];
    my $key1;
    return POST ($c, q</email/input>, params => {
      addr => q<foo@hoge.test>,
    }, session => $session)->then (sub {
      my $json = $_[0];
      test {
        ok $key1 = $json->{key};
      } $c;
      return POST ($c, q</email/input>, params => {
        addr => q<foo@hoge.test>,
      }, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        ok $json->{key};
        isnt $json->{key}, $key1;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 3, name => '/email/input associated';

test {
  my $c = shift;
  return session ($c, account => {email => q<foo@hoge.test>})->then (sub {
    my $session = $_[0];
    my $key1;
    return POST ($c, q</email/input>, params => {
      addr => q<foo@hoge.test>,
    }, session => $session)->then (sub {
      my $json = $_[0];
      test {
        is $json->{key}, undef;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 1, name => '/email/input already associated';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
