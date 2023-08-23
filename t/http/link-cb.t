use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {}, session => 1);
  })->then (sub {
    return $current->post (['link'], {
      server => 'oauth1server',
      callback_url => 'http://haoa/',
    }, session => 1);
  })->then (sub {
    return $current->post (['cb'], {}, session => 1);
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{reason}, 'Bad |state|';
    } $current->c;
  });
} n => 2, name => '/link then /cb';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  return $current->create_session (1)->then (sub {
    $current->set_o (time1 => time);
    return $current->post (['create'], {}, session => 1);
  })->then (sub {
    $current->set_o (time2 => time);
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    $account_id = $result->{json}->{account_id};
    return $current->post (['link'], {
      server => 'oauth1server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST'); # user accepted!
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
      is $result->{app_data}, undef;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{account_id}, $account_id;
      my $links = $result->{json}->{links};
      my $l = [grep { $_->{service_name} eq 'oauth1server' } values %$links]->[0];
      ok $l->{created};
      ok $l->{updated};
      ok $l->{account_link_id};
      ok $current->o ('time1') < $result->{json}->{login_time}, $current->o ('time1');
      ok $result->{json}->{login_time} < $current->o ('time2'), $current->o ('time2');
    } $current->c, name => $result->{json}->{login_time};
  });
} n => 12, name => '/link then auth then /cb - oauth1';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $x_account_id = int rand 100000;
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
    my $con = $current->client_for ($url);
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
      is $result->{json}->{app_data}, undef;
      is $result->{json}->{is_new}, undef;
      is $result->{json}->{lk}, undef;
      is $result->{json}->{lk_expires}, undef;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is $ls->[0]->{id}, $x_account_id;
      is $result->{json}->{account_id}, $account_id, 'linked account';
    } $current->c;
  })->then (sub {
    return $current->create_session (2);
  })->then (sub {
    return $current->post (['login'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 2);
  })->then (sub {
    my $result = $_[0];
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_id => $x_account_id,
    }); # user accepted!
  })->then (sub {
    my $result = $_[0];
    my $location = $result->header ('Location');
    my ($base, $query) = split /\?/, $location, 2;
    return $current->post ("/cb?$query", {}, session => 2);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{app_data}, undef;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 2);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is $ls->[0]->{id}, $x_account_id;
      is $result->{json}->{account_id}, $account_id, 'existing account';
      ok $ls->[0]->{created};
      ok $ls->[0]->{updated};
      ok $ls->[0]->{account_link_id};
    } $current->c;
  });
} n => 19, name => '/link then auth then /cb - oauth2';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $x_account_id = int rand 1000000;
  return $current->create_session (1)->then (sub {
    return $current->post (['login'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
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
      is $result->{json}->{app_data}, undef;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      ok grep { $_->{service_name} eq 'oauth2server' } values %$links;
      ok $account_id = $result->{json}->{account_id}, 'new account';
    } $current->c;
  })->then (sub {
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_name => "\x{5001}\x{5700}",
      account_id => $x_account_id,
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
      is $result->{json}->{app_data}, undef;
    } $current->c;
    return $current->post (['info'], {with_linked => ['id', 'name']}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is 0+@$ls, 1;
      is $ls->[0]->{name}, "\x{5001}\x{5700}", 'account_name updated';
      is $ls->[0]->{id}, $x_account_id;
      is $result->{json}->{account_id}, $account_id, 'existing account linked';
    } $current->c;
  });
} n => 15, name => 'link to existing account, same account ID';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $name1 = rand;
  my $id1 = int rand 100000;
  my $name2 = rand;
  my $id2 = int rand 100000;
  return $current->create_session (1)->then (sub {
    return $current->post (['login'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_id => $id1,
      account_name => $name1,
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
      is $result->{json}->{app_data}, undef;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      ok grep { $_->{service_name} eq 'oauth2server' } values %$links;
      ok $account_id = $result->{json}->{account_id}, 'new account';
    } $current->c;
  })->then (sub {
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_name => $name2,
      account_id => $id2,
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
      is $result->{json}->{app_data}, undef;
    } $current->c;
    return $current->post (['info'], {with_linked => ['id', 'name']}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is 0+@$ls, 2;
      my $link1 = [grep { $_->{name} eq $name1 } values %$links]->[0];
      my $link2 = [grep { $_->{name} eq $name2 } values %$links]->[0];
      is $link1->{id}, $id1;
      ok $link1->{account_link_id};
      is $link2->{id}, $id2;
      ok $link2->{account_link_id};
      isnt $link2->{account_link_id}, $link1->{account_link_id};
      is $result->{json}->{account_id}, $account_id, 'existing account linked';
      like $result->{res}->body_bytes, qr{"account_link_id"\s*:\s*"};
    } $current->c;
  });
} n => 19, name => 'link to existing account, different account ID';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $x_account_id = int rand 1000000;
  return $current->create_session (1)->then (sub {
    return $current->post (['login'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_name => "old account",
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
      is $result->{json}->{app_data}, undef;
    } $current->c;
    return $current->post (['info'], {with_linked => 'id'}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      ok grep { $_->{service_name} eq 'oauth2server' } values %$links;
      ok $account_id = $result->{json}->{account_id}, 'new account';
    } $current->c;
    return $current->create_session (2);
  })->then (sub {
    return $current->post (['create'], {}, session => 2);
  })->then (sub {
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 2);
  })->then (sub {
    my $result = $_[0];
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_name => "\x{5001}\x{5700}",
      account_id => $x_account_id,
    }); # user accepted!
  })->then (sub {
    my $result = $_[0];
    my $location = $result->header ('Location');
    my ($base, $query) = split /\?/, $location, 2;
    return $current->post ("/cb?$query", {}, session => 2);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{app_data}, undef;
    } $current->c;
    return $current->post (['info'], {with_linked => ['id', 'name']}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is $ls->[0]->{name}, 'old account';
    } $current->c;
    return $current->post (['info'], {with_linked => ['id', 'name']}, session => 2);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is $ls->[0]->{name}, "\x{5001}\x{5700}", 'account_name';
      is $ls->[0]->{id}, $x_account_id;
    } $current->c;
  });
} n => 15, name => 'link to linked-with-another-account account';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $name1 = rand;
  my $name2 = rand;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {}, session => 1);
  })->then (sub {
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
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_no_id => 1,
      account_name => $name1,
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
      is $result->{json}->{app_data}, undef;
    } $current->c;
    return $current->post (['info'], {with_linked => ['id', 'name']}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is 0+@$ls, 1;
      is $ls->[0]->{id}, undef;
      is $ls->[0]->{name}, $name1;
      ok $account_id = $result->{json}->{account_id};
    } $current->c;
  })->then (sub {
    return $current->post (['link'], {
      server => 'oauth2server',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    my $con = $current->client_for ($url);
    return $con->request (url => $url, method => 'POST', params => {
      account_name => $name2,
      account_no_id => 1,
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
      is $result->{json}->{app_data}, undef;
    } $current->c;
    return $current->post (['info'], {with_linked => ['id', 'name']}, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $links = $result->{json}->{links};
      my $ls = [grep { $_->{service_name} eq 'oauth2server' } values %$links];
      is 0+@$ls, 1;
      is $ls->[0]->{id}, undef;
      is $ls->[0]->{name}, $name2;
      is $result->{json}->{account_id}, $account_id, 'existing account linked';
    } $current->c;
  });
} n => 17, name => 'linked to account without ID';

Test {
  my $current = shift;
  my $cb_url = 'http://haoa/' . rand;
  my $account_id;
  my $x_account_id = int rand 100000;
  return $current->create_session (1)->then (sub {
    return $current->post (['create'], {}, session => 1);
  })->then (sub {
    return $current->post (['info'], {}, session => 1);
  })->then (sub {
    my $result = $_[0];
    $account_id = $result->{json}->{account_id};
    return $current->post (['link'], {
      server => 'oauth2server_wrapped',
      callback_url => $cb_url,
    }, session => 1);
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
    } $current->c;
    my $url = Web::URL->parse_string ($result->{json}->{authorization_url});
    test {
      $url->query =~ m{redirect_uri=([^&]+)};
      my $u = percent_decode_c $1;
      is $u, qq{http://cb.wrapper.test/wrapper/@{[percent_encode_c $cb_url]}?url=@{[percent_encode_c $cb_url]}&test=1};
    } $current->c;
  });
} n => 2, name => 'wrapped /cb URL';

RUN;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
