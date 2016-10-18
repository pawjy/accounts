use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

my $wait = web_server;

Test {
  my $current = shift;
  return $current->create_session (1)->then (sub {
    return $current->post (['login'], {
      server => 'oauth1server',
      callback_url => 'http://haoa/',
    }, session => 1);
  })->then (sub {
    return $current->post (['cb'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad |state|';
    } $current->context;
  });
} wait => $wait, n => 2, name => '/login then /cb';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  return $current->create_session (1)->then (sub {
    return $current->post (['login'], {
      server => 'oauth1server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->context;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = Web::Transport::ConnectionClient->new_from_url ($url);
    return $con->request (url => $url, method => 'POST'); # user accepted!
  })->then (sub {
    my $result = $_[0];
    return test {
      is $result->status, 302;
      my $location = $result->header ('Location');
      my ($base, $query) = split /\?/, $location, 2;
      is $base, $cb_url;
      return $current->post ("/cb?$query", {}, session => 1);
    } $current->context;
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{app_data}, undef;
    } $current->context;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      ok grep { $_->{service_name} eq 'oauth1server' } values %$links;
    } $current->context;
  });
} wait => $wait, n => 7, name => '/login then auth then /cb - new account, oauth1';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  return $current->create_session (1)->then (sub {
    return $current->post (['login'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->context;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = Web::Transport::ConnectionClient->new_from_url ($url);
    return $con->request (url => $url, method => 'POST'); # user accepted!
  })->then (sub {
    my $result = $_[0];
    return test {
      is $result->status, 302;
      my $location = $result->header ('Location');
      my ($base, $query) = split /\?/, $location, 2;
      is $base, $cb_url;
      return $current->post ("/cb?$query", {}, session => 1);
    } $current->context;
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{app_data}, undef;
    } $current->context;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      ok grep { $_->{service_name} eq 'oauth2server' } values %$links;
    } $current->context;
  });
} wait => $wait, n => 7, name => '/login then auth then /cb - new account, oauth2';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2015-2016 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
