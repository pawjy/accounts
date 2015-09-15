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
  return session ($c, account => 1)->then (sub {
    my $session = $_[0];
    return GET ($c, q</agree>, params => {
      version => 10,
    }, session => $session)->then (sub { test { ok 0 } $c }, sub {
      my $error = $_[0];
      test {
        is $error, 405;
      } $c;
      return POST ($c, q</info>, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{terms_version}, 0;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 2, name => '/agree GET';

test {
  my $c = shift;
  return session ($c, account => 1)->then (sub {
    my $session = $_[0];
    return POST ($c, q</agree>, params => {
      version => 10,
    }, bad_bearer => 1, session => $session)->then (sub { test { ok 0 } $c }, sub {
      my $error = $_[0];
      test {
        is $error, 401;
      } $c;
      return POST ($c, q</info>, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{terms_version}, 0;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 2, name => '/agree bad API key';

test {
  my $c = shift;
  return POST ($c, q</agree>, params => {
    version => 10,
  })->then (sub { test { ok 0 } $c }, sub {
    my $json = $_[0];
    test {
      is $json->{reason}, 'Not a login user';
    } $c;
    done $c;
    undef $c;
  });
} wait => $wait, n => 1, name => '/agree no session';

test {
  my $c = shift;
  return session ($c, account => 0)->then (sub {
    my $session = $_[0];
    return POST ($c, q</agree>, params => {
      version => 10,
    }, session => $session)->then (sub { test { ok 0 } $c }, sub {
      my $json = $_[0];
      test {
        is $json->{reason}, 'Not a login user';
      } $c;
      return POST ($c, q</info>, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{terms_version}, undef;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 2, name => '/agree no account';

test {
  my $c = shift;
  return session ($c, account => 1)->then (sub {
    my $session = $_[0];
    return POST ($c, q</agree>, params => {
    }, session => $session)->then (sub {
      my $json = $_[0];
      test {
        is ref $json, 'HASH';
      } $c;
      return POST ($c, q</info>, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{terms_version}, 0;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 2, name => '/agree no |version|';

test {
  my $c = shift;
  return session ($c, account => 1)->then (sub {
    my $session = $_[0];
    return POST ($c, q</agree>, params => {
      version => 10,
    }, session => $session)->then (sub {
      my $json = $_[0];
      test {
        is ref $json, 'HASH';
      } $c;
      return POST ($c, q</info>, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{terms_version}, 10;
      } $c;
      return POST ($c, q</agree>, params => {
        version => 12,
      }, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is ref $json, 'HASH';
      } $c;
      return POST ($c, q</info>, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{terms_version}, 12;
      } $c;
      return POST ($c, q</agree>, params => {
      }, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is ref $json, 'HASH';
      } $c;
      return POST ($c, q</info>, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{terms_version}, 12;
      } $c;
      return POST ($c, q</agree>, params => {
        version => 3,
      }, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is ref $json, 'HASH';
      } $c;
      return POST ($c, q</info>, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{terms_version}, 12;
      } $c;
      return POST ($c, q</agree>, params => {
        version => 255,
      }, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is ref $json, 'HASH';
      } $c;
      return POST ($c, q</info>, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{terms_version}, 255;
      } $c;
      return POST ($c, q</agree>, params => {
        version => 256,
      }, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is ref $json, 'HASH';
      } $c;
      return POST ($c, q</info>, session => $session);
    })->then (sub {
      my $json = $_[0];
      test {
        is $json->{terms_version}, 255;
      } $c;
      done $c;
      undef $c;
    });
  });
} wait => $wait, n => 12, name => '/agree updated';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
