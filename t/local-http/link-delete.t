use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $x_account_id = int rand 100000;
  my $x_account_id2 = int rand 100000;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {}, session => 1);
  })->then (sub {
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    $account_id = $result->{json}->{account_id};
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = Web::Transport::ConnectionClient->new_from_url ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_id => $x_account_id,
    }); # user accepted!
  })->then (sub {
    my $result = $_[0];
    return test {
      is $result->status, 302;
      my $location = $result->header ('Location');
      my ($base, $query) = split /\?/, $location, 2;
      is $base, $cb_url;
      return $current->post ("/cb?$query", {}, session => 1);
    } $current->c;
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is 0+@$ls, 1;
    } $current->c;
  })->then (sub {
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = Web::Transport::ConnectionClient->new_from_url ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_id => $x_account_id2,
    }); # user accepted!
  })->then (sub {
    my $result = $_[0];
    my $location = $result->header ('Location');
    my ($base, $query) = split /\?/, $location, 2;
    return $current->post ("/cb?$query", {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $links = $result->{json}->{links};
    my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
    test {
      is $result->{status}, 200;
      is 0+@$ls, 2;
    } $current->c;
    return $current->post (['link', 'delete'], {
      account_id => $account_id,
      account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id2 } @$ls],
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{status}, 200;
      } $current->c;
      return $current->post (['info'], {with_linked => 'id'}, session => 1);
    })->then (sub {
      my $result = $_[0];
      my $links = $result->{json}->{links};
      my $ls2 = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      test {
        is $result->{status}, 200;
        is 0+@$ls2, 1;
        is $ls2->[0]->{id}, $x_account_id;
      } $current->c;
      return $current->post (['link', 'delete'], {
        account_id => $account_id . '1',
        account_link_id => [map { $_->{account_link_id} } grep { $_->{id} eq $x_account_id } @$ls],
      });
    })->then (sub {
      my $result = $_[0];
      test {
        is $result->{status}, 200;
      } $current->c;
      return $current->post (['info'], {with_linked => 'id'}, session => 1);
    })->then (sub {
      my $result = $_[0];
      my $links = $result->{json}->{links};
      my $ls2 = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      test {
        is $result->{status}, 200;
        is 0+@$ls2, 1;
        is $ls2->[0]->{id}, $x_account_id;
      } $current->c, name => 'wrong account id cant remove account link';
    });
  });
} n => 17, name => '/link/delete';

RUN;

=head1 LICENSE

Copyright 2015-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
