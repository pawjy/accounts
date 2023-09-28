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
        {params => {source_data => 'abc'}, status => 400},
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
      source_ua => $current->generate_key (k1 => {}),
      source_ipaddr => $current->generate_key (k2 => {}),
      source_data => perl2json_chars ({
        abc => $current->generate_key (k3 => {}),
      }),
    }, session => 's1');
  })->then (sub {
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{terms_version}, 0;
    } $current->c;
    return $current->post (['log', 'get'], {
      action => 'agree',
      use_sk => 1,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 8;
      {
        my $item = $result->{json}->{items}->[0];
        is $item->{account_id}, $current->o ('s1')->{account}->{account_id};
        is $item->{action}, 'agree';
        is $item->{operator_account_id}, $item->{account_id};
        is $item->{ua}, $current->o ('k1');
        is $item->{ipaddr}, $current->o ('k2');
        is $item->{data}->{source_operation}, 'agree';
        is $item->{data}->{source_data}->{abc}, $current->o ('k3');
        is $item->{data}->{version}, 0;
        ok $item->{log_id};
        ok $item->{timestamp};
      }
    } $current->c;
  });
} n => 20, name => '/agree updated';

Test {
  my $current = shift;
  return $current->create (
    [s1 => session => {}],
  )->then (sub {
    return $current->post (['login'], {
      server => 'oauth1server',
      callback_url => 'http://haoa/',
      app_data => $current->generate_text (t1 => {}),
    }, session => 's1');
  })->then (sub {
    return $current->post (['create'], {
    }, session => 's1');
  })->then (sub {
    return $current->post (['agree'], {
      version => 10,
    }, session => 's1');
  })->then (sub {
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{terms_version}, 10;
    } $current->c;
  });
} n => 1, name => '/agree with utf8 flagged info';

RUN;

=head1 LICENSE

Copyright 2015-2023 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
