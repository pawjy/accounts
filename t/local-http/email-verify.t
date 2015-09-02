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
  return GET ($c, q</email/verify>)->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 405;
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/email/verify GET';

test {
  my $c = shift;
  return POST ($c, q</email/verify>, bad_bearer => 1)->then (sub { test { ok 0 } $c }, sub {
    my $status = $_[0];
    test {
      is $status, 401;
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/email/verify POST bad bearer';

test {
  my $c = shift;
  return POST ($c, q</email/verify>)->then (sub { test { ok 0 } $c }, sub {
    my $json = $_[0];
    test {
      is $json->{reason}, 'Bad session';
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/email/verify POST no args';

test {
  my $c = shift;
  return POST ($c, q</email/verify>, params => {
    key => q<abcdef>,
  })->then (sub { test { ok 0 } $c }, sub {
    my $json = $_[0];
    test {
      is $json->{reason}, 'Bad session';
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/email/verify POST bad session';

test {
  my $c = shift;
  return session ($c)->then (sub {
    my $session = $_[0];
    my $key1;
    return POST ($c, q</email/verify>, params => {
      key => q<abcde>,
    }, session => $session)->then (sub { test { ok 0 } $c }, sub {
      my $json = $_[0];
      test {
        is $json->{reason}, 'Not a login user';
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 1, name => '/email/verify no account';

test {
  my $c = shift;
  return session ($c, account => 1)->then (sub {
    my $session = $_[0];
    return POST ($c, q</email/verify>, params => {
    }, session => $session)->then (sub { test { ok 0 } $c }, sub {
      my $json = $_[0];
      test {
        is $json->{reason}, 'Bad key';
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 1, name => '/email/verify bad key';

test {
  my $c = shift;
  return session ($c, account => 1)->then (sub {
    my $session = $_[0];
    return POST ($c, q</email/verify>, params => {
      key => q<abcde>,
    }, session => $session)->then (sub { test { ok 0 } $c }, sub {
      my $json = $_[0];
      test {
        is $json->{reason}, 'Bad key';
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 1, name => '/email/verify bad key';

test {
  my $c = shift;
  return session ($c, account => 1)->then (sub {
    my $session = $_[0];
    my $key1;
    return POST ($c, q</email/input>, params => {
      addr => q<foo@bar.test>,
    }, session => $session)->then (sub {
      my $json = $_[0];
      $key1 = $json->{key};
      return POST ($c, q</email/verify>, params => {
        key => $key1,
      }, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is ref $json, 'HASH', 'association done';
      } $c;
      return POST ($c, q</email/verify>, params => {
        key => $key1,
      }, session => $session);
    })->then (sub { test { ok 0 } $c }, sub {
      my $json = $_[0];
      test {
        is $json->{reason}, 'Bad key', 'Key can be used only once';
      } $c;
      return POST ($c, q</info>, params => {
        with_linked => ['id', 'key', 'name', 'email'],
      }, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is 0+keys %{$json->{links}}, 1;
        my $link = [values %{$json->{links}}]->[0];
        is $link->{service_name}, 'email';
        ok $link->{id};
        is $link->{email}, q<foo@bar.test>;
        is $link->{key}, undef;
        is $link->{name}, undef;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 8, name => '/email/verify associated';

test {
  my $c = shift;
  return session ($c, account => 1)->then (sub {
    my $session = $_[0];
    my $key1;
    my $key2;
    return POST ($c, q</email/input>, params => {
      addr => q<foo@bar.test>,
    }, session => $session)->then (sub {
      $key1 = $_[0]->{key};
      return POST ($c, q</email/input>, params => {
        addr => q<baz@bar.test>,
      }, session => $session);
    })->then (sub {
      $key2 = $_[0]->{key};
      return POST ($c, q</email/verify>, params => {
        key => $key1,
      }, session => $session);
    })->then (sub {
      return POST ($c, q</email/verify>, params => {
        key => $key2,
      }, session => $session);
    })->then (sub {
      return POST ($c, q</info>, params => {
        with_linked => ['id', 'key', 'name', 'email'],
      }, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is 0+keys %{$json->{links}}, 2;
        my $actual = [sort { $a cmp $b } map { $_->{email} } values %{$json->{links}}];
        is $actual->[0], 'baz@bar.test';
        is $actual->[1], 'foo@bar.test';
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 3, name => '/email/verify multiple association';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
