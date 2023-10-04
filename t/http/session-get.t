use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->are_errors (
    [['session', 'get'], {sk_context => rand}],
    [
      {method => 'GET', status => 405},
      {bearer => undef, status => 401},
      {params => {}, status => 400, reason => 'No |account_id|'},
    ],
  )->then (sub {
    return $current->post (['session', 'get'], {
      account_id => 1344,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+@{$result->{json}->{items}}, 0;
    } $current->c;
  });
} n => 2, name => '/session/get';

Test {
  my $current = shift;
  $current->generate_id (i1 => {});
  return $current->create (
    [s1 => session => {}],
    [s2 => session => {}],
    [s3 => session => {}],
    [s4 => session => {}],
    [s5 => session => {}],
  )->then (sub {
    my $cb_url = 'http://haoa/' . rand;
    $current->generate_id (xa1 => {});
    return promised_for {
      my $session = shift;
      return $current->post (['login'], {
        server => 'oauth2server',
        callback_url => $cb_url,
      }, session => $session)->then (sub {
        my $result = $_[0];
        my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
        my $con = $current->client_for ($url);
        return $con->request (url => $url, method => 'POST', params => {
          account_id => $current->o ('xa1'),
        });
      })->then (sub {
        my $result = $_[0];
        my $location = $result->header ('Location');
        my ($base, $query) = split /\?/, $location, 2;
        $current->o ($session)->{ua} = $current->generate_key (rand, {});
        return $current->post ("/cb?$query", {
          source_ua => $current->o ($session)->{ua},
        }, session => $session);
      });
    } ['s1', 's2', 's3', 's4', 's5'];
  })->then (sub {
    return $current->post (['info'], {
    }, session => "s1");
  })->then (sub {
    $current->set_o (a1 => $_[0]->{json});
    return $current->pages_ok ([['session', 'get'], {
      account_id => $current->o ('a1')->{account_id},
    }] => ['s1', 's2', 's3', 's4', 's5'], 'ua', undef, items => sub {
      for (@{$_[0]}) {
        $_->{ua} = $_->{log_data}->{ua};
      }
      return $_[0];
    });
  });
} n => 1, name => 'paging';

## See also: t/http/create.t

RUN;

=head1 LICENSE

Copyright 2023 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
