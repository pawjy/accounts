use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create_session (s1 => {})->then (sub {
    return $current->are_errors (
      [['token'], {
        server => 'oauth1server',
        sk => $current->o ('s1')->{sk},
      }],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {params => {sk => $current->o ('s1')->{sk}}, status => 400, name => 'no server'},
        {params => {sk => $current->o ('s1')->{sk}, server => 'hoge'}, status => 400, name => 'bad server'},
      ],
    );
  })->then (sub {
    return $current->post (['token'], {
      server => 'oauth1server',
      sk => $current->o ('s1')->{sk},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, undef;
    } $current->c;
  });
} n => 3, name => '/token has anon session';

Test {
  my $current = shift;
  return Promise->resolve->then (sub {
    return $current->post (['token'], {
      server => 'oauth1server',
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, undef;
    } $current->c;
  });
} n => 2, name => '/token has no session';

Test {
  my $current = shift;
  return $current->create_session (s1 => {})->then (sub {
    return $current->post (['token'], {
      server => 'oauth1server',
      sk => rand,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, undef;
    } $current->c;
  });
} n => 2, name => '/token has bad session';

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->post (['token'], {
      server => 'oauth1server',
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{access_token}, undef;
      is $result->{json}->{account_id}, $current->o ('a1')->{account_id};
    } $current->c;
  });
} n => 2, name => '/token has account_id no token';

RUN;

=head1 LICENSE

Copyright 2015-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
