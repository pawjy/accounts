use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Web::URL;

sub setup_multiple_linked_accounts ($) {
  my ($current) = @_;
  my $cb_url = 'http://haoa.test/cb/' . rand;
  my $x_account_id = 'xid_' . int rand 1000000;
  my ($account_id_A, $account_id_B);

  my $setup_promise = Promise->all([
      $current->create_session(2), $current->create_session(3),
  ])->then(sub{
      return Promise->all([
          $current->post(['create'], { name => 'Account A'}, session => 2),
          $current->post(['create'], { name => 'Account B'}, session => 3),
      ]);
  })->then(sub {
      my ($res_A, $res_B) = @{$_[0]};
      $account_id_A = $res_A->{json}->{account_id};
      $account_id_B = $res_B->{json}->{account_id};
      
      return Promise->all([
          $current->post(['link', 'add'], { server => 'oauth2server', linked_id => $x_account_id }, session => 2),
          $current->post(['link', 'add'], { server => 'oauth2server', linked_id => $x_account_id }, session => 3),
      ]);
  });

  return $setup_promise->then(sub { return { 
    cb_url => $cb_url, x_account_id => $x_account_id, 
    account_id_A => $account_id_A, account_id_B => $account_id_B 
  } });
}

sub setup_single_linked_account ($) {
    my ($current) = @_;
    my $cb_url = 'http://haoa.test/cb/' . rand;
    my $x_account_id = 'xid_' . int rand 1000000;
    my $account_id;

    return $current->create_session(2)->then(sub {
        return $current->post(['create'], { name => 'Single Account' }, session => 2);
    })->then(sub {
        my $res = $_[0];
        $account_id = $res->{json}->{account_id};
        return $current->post(['link', 'add'], { server => 'oauth2server', linked_id => $x_account_id }, session => 2);
    })->then(sub {
        return { cb_url => $cb_url, x_account_id => $x_account_id, account_id => $account_id };
    });
}

Test {
  my $current = shift;
  return $current->create (
    [1 => session => {}],
    [s2 => session => {account => 1}],
  )->then (sub {
    return $current->are_errors (
      [['login', 'continue'], {
        selected_account_id => 123,
      }, session => '1'],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {session => undef, status => 400, reason => 'Bad session'},
        {session => '1', status => 400, reason => 'Bad login flow state'},
        {session => 's2', status => 400, reason => 'Bad login flow state'},
        {params => {}, status => 400, reason => 'No |selected_account_id|'},
      ],
    );
  })->then (sub {
    return setup_single_linked_account($current)->then(sub {
      my $o = $_[0];
      return $current->post(['login'], {
        server => 'oauth2server',
        callback_url => $o->{cb_url},
        select_account_on_multiple => 0,
      }, session => 1)->then(sub {
        my $url = Web::URL->parse_string($_[0]->{json}->{authorization_url});
                return $current->client_for($url)->request(url => $url, method => 'POST', params => { account_id => $o->{x_account_id} });
            })->then(sub {
                my ($base, $query) = split /\?/, $_[0]->header('Location'), 2;
                return $current->post("/cb?$query", {}, session => 1);
            })->then(sub {
                my $result = $_[0];
                test {
                    is $result->{status}, 200, 'Simple case: /cb returns 200';
                    is $result->{json}->{needs_account_selection}, undef, 'Simple case: no selection is requested for a single account';
                } $current->c;
                # Verify we are logged in immediately.
                return $current->post(['info'], {}, session => 1);
            })->then(sub {
                my $result = $_[0];
                test { is $result->{json}->{account_id}, $o->{account_id}, 'Simple case: logged in automatically' } $current->c;
            });
        });
  });
} n => 4, name => 'Basic error checks and regression for single-account login';

Test {
  my $current = shift;
  return $current->create_session(1)->then(sub { # Session for the main flow
    return setup_multiple_linked_accounts($current)->then(sub {
      my $o = $_[0];
      return $current->post(['login'], {
        server => 'oauth2server',
        callback_url => $o->{cb_url},
        select_account_on_multiple => 1,
      }, session => 1)->then(sub {
        my $url = Web::URL->parse_string($_[0]->{json}->{authorization_url});
        return $current->client_for($url)->request(url => $url, method => 'POST', params => { account_id => $o->{x_account_id} });
      })->then(sub {
        my ($base, $query) = split /\?/, $_[0]->header('Location'), 2;
        return $current->post("/cb?$query", {}, session => 1);
      })->then(sub {
        my $result = $_[0];
        test {
          is $result->{status}, 200, '/cb returns 200';
          is $result->{json}->{needs_account_selection}, 1, '/cb response has needs_account_selection flag';
          is 0+@{$result->{json}->{accounts}}, 2, '/cb response has 2 accounts';
        } $current->c;
        return $current->post(['login', 'continue'], { selected_account_id => $o->{account_id_B} }, session => 1);
      })->then(sub {
        my $result = $_[0];
        test { is $result->{status}, 200, '/login/continue returns 200' } $current->c;
        return $current->post(['info'], {}, session => 1);
      })->then(sub {
        my $result = $_[0];
        test { is $result->{json}->{account_id}, $o->{account_id_B}, 'Successfully logged in as the selected account' } $current->c;
      });
    });
  });
} n => 5, name => 'Happy Path: Account selection and continuation';

Test {
  my $current = shift;
  return $current->create_session(1)->then(sub { # Session for the main flow
    return setup_multiple_linked_accounts($current)->then(sub {
      my $o = $_[0];
      return $current->post(['login'], { server => 'oauth2server', callback_url => $o->{cb_url}, select_account_on_multiple => 1 }, session => 1)->then(sub {
        my $url = Web::URL->parse_string($_[0]->{json}->{authorization_url});
        return $current->client_for($url)->request(url => $url, method => 'POST', params => { account_id => $o->{x_account_id} });
      })->then(sub {
        my ($base, $query) = split /\?/, $_[0]->header('Location'), 2;
        return $current->post("/cb?$query", {}, session => 1);
      })->then(sub {
        return $current->post(['login', 'continue'], { selected_account_id => 'bogus-id' }, session => 1);
      })->then(sub { test { ok 0, 'Should have failed' } $current->c }, sub {
        my $result = $_[0];
        test {
          is $result->{status}, 400, 'Invalid account selection returns 400';
          is $result->{json}->{reason}, 'Selected account did not match linked accounts', 'Correct error reason for invalid selection';
        } $current->c;
      });
    });
  });
} n => 2, name => 'Error Path: Invalid account selection with bogus ID';

Test {
  my $current = shift;
  return $current->create_session(1)->then(sub { # Session for the main flow
    return setup_multiple_linked_accounts($current)->then(sub {
      my $o = $_[0];
      return $current->create_session(3)->then(sub {
        return $current->post(['create'], { name => 'Account C'}, session => 3);
      })->then(sub {
        my $res_C = $_[0];
        my $account_id_C = $res_C->{json}->{account_id};

        return $current->post(['login'], { server => 'oauth2server', callback_url => $o->{cb_url}, select_account_on_multiple => 1 }, session => 1)->then(sub {
            my $url = Web::URL->parse_string($_[0]->{json}->{authorization_url});
            return $current->client_for($url)->request(url => $url, method => 'POST', params => { account_id => $o->{x_account_id} });
        })->then(sub {
            my ($base, $query) = split /\?/, $_[0]->header('Location'), 2;
            return $current->post("/cb?$query", {}, session => 1);
        })->then(sub {
          return $current->post(['login', 'continue'], { selected_account_id => $account_id_C }, session => 1);
        });
      });
    });
  })->then(sub {
      test { ok 0, 'Should have failed' } $current->c;
  }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400, 'Using unlisted-but-valid account ID returns 400';
      is $result->{json}->{reason}, 'Selected account did not match linked accounts', 'Correct error for unlisted account';
    } $current->c;
  });
} n => 2, name => 'Error Path: Selecting a valid but unlisted account';

Test {
  my $current = shift;
  return $current->create_session(1)->then(sub { # Session for the main flow
    return setup_multiple_linked_accounts($current)->then(sub {
      my $o = $_[0];
      return $current->post(['login'], { server => 'oauth2server', callback_url => $o->{cb_url}, select_account_on_multiple => 1 }, session => 1)->then(sub {
                my $url = Web::URL->parse_string($_[0]->{json}->{authorization_url});
                return $current->client_for($url)->request(url => $url, method => 'POST', params => { account_id => $o->{x_account_id} });
            })->then(sub {
                my ($base, $query) = split /\?/, $_[0]->header('Location'), 2;
                return $current->post("/cb?$query", {}, session => 1);
              })->then(sub {
                return $current->post(['login'], { server => 'oauth2server', callback_url => 'http://f.test/cb' }, session => 1);
            });
        });
    })->then(sub {
        my $result = $_[0];
        test {
            is $result->{status}, 200, 'Calling /login again while selection is pending succeeds';
            ok $result->{json}->{authorization_url}, 'A new authorization URL is returned';
        } $current->c;
    });
} n => 2, name => 'Edge Case: Calling /login again while selection is pending';

Test {
  my $current = shift;
  return $current->create_session(1)->then(sub { # Session for the main flow
    return setup_multiple_linked_accounts($current)->then(sub {
      my $o = $_[0];
      return $current->post(['login'], { server => 'oauth2server', callback_url => $o->{cb_url} }, session => 1)->then(sub {
        my $url = Web::URL->parse_string($_[0]->{json}->{authorization_url});
        return $current->client_for($url)->request(url => $url, method => 'POST', params => { account_id => $o->{x_account_id} });
      })->then(sub {
        my ($base, $query) = split /\?/, $_[0]->header('Location'), 2;
        return $current->post("/cb?$query", {}, session => 1);
      })->then(sub {
        my $result = $_[0];
        test {
          is $result->{status}, 200, 'Backward compat: /cb returns 200';
          is $result->{json}->{needs_account_selection}, undef, 'Backward compat: no account selection is requested';
        } $current->c;
        return $current->post(['info'], {}, session => 1);
      })->then(sub {
        my $result = $_[0];
        test {
          if ($result->{json}->{account_id} eq $o->{account_id_B}) {
            is $result->{json}->{account_id}, $o->{account_id_B};
          } else {
            is $result->{json}->{account_id}, $o->{account_id_A};
          }
        } $current->c;
      });
    });
  });
} n => 3, name => 'Backward Compatibility: Both accounts active';

Test {
  my $current = shift;
  return $current->create_session(1)->then(sub { # Session for the main flow
    return setup_multiple_linked_accounts($current)->then(sub {
      my $o = $_[0];
      return $current->post(['account', 'user_status'], { account_id => $o->{account_id_A}, user_status => 2 }, session => 1)->then(sub { return $o });
    })->then(sub {
      my $o = $_[0];
      return $current->post(['login'], { server => 'oauth2server', callback_url => $o->{cb_url} }, session => 1)->then(sub {
        my $url = Web::URL->parse_string($_[0]->{json}->{authorization_url});
        return $current->client_for($url)->request(url => $url, method => 'POST', params => { account_id => $o->{x_account_id} });
      })->then(sub {
        my ($base, $query) = split /\?/, $_[0]->header('Location'), 2;
        return $current->post("/cb?$query", {}, session => 1);
      })->then(sub {
        my $result = $_[0];
        test {
          is $result->{status}, 200, 'Auto-skip inactive: /cb returns 200';
          is $result->{json}->{needs_account_selection}, undef, 'Auto-skip inactive: no selection requested';
        } $current->c;
        return $current->post(['info'], {}, session => 1)->then (sub {
          my $result = $_[0];
          test { is $result->{json}->{account_id}, $o->{account_id_B}, 'Auto-skip inactive: logged into the only active account' } $current->c;
        });
      }, sub {
        my $e = $_[0];
        test {
          is $e->{status}, 400;
          is $e->{json}->{reason}, "Bad account |user_status|";
        } $current->c;
        return $current->post(['info'], {}, session => 1)->then (sub {
          my $result = $_[0];
          test {
            is $result->{json}->{account_id}, undef;
          } $current->c;
        });
      });
    });
  });
} n => 3, name => 'Backward Compatibility: One account inactive';

Test {
  my $current = shift;
  $current->create_session(1)->then(sub { # Session for the main flow
    return setup_multiple_linked_accounts($current)->then(sub {
      my $o = $_[0];
      return $current->post(['account', 'user_status'], { account_id => $o->{account_id_A}, user_status => 2 }, session => 1)->then(sub {
        return $current->post(['account', 'admin_status'], { account_id => $o->{account_id_B}, admin_status => 2 }, session => 1);
      })->then(sub { return $o; });
    })->then(sub {
      my $o = $_[0];
      return $current->post(['login'], { server => 'oauth2server', callback_url => $o->{cb_url}, select_account_on_multiple => 1 }, session => 1)->then(sub {
        my $url = Web::URL->parse_string($_[0]->{json}->{authorization_url});
        return $current->client_for($url)->request(url => $url, method => 'POST', params => { account_id => $o->{x_account_id} });
      })->then(sub {
        my ($base, $query) = split /\?/, $_[0]->header('Location'), 2;
        return $current->post("/cb?$query", {}, session => 1);
      });
    })->then(sub {
      my $result = $_[0];
      test {
        is 0+@{$result->{json}->{accounts}}, 2;
        like $result->{res}->body_bytes, qr{"account_id":"};
      } $current->c;
      return $current->post(['login', 'continue'], {
        selected_account_id => $result->{json}->{accounts}->[0]->{account_id},
      }, session => 1);
    })->then (sub {
      test {
        ok 0;
        ok 0;
        ok 0;
      } $current->c;
    }, sub {
        my $result = $_[0];
        test {
          is $result->{status}, 400, 'All candidates invalid: Login fails with 400';
          ok $result->{json}->{reason} eq 'Bad account |user_status|' || $result->{json}->{reason} eq 'Bad account |admin_status|', 'All candidates invalid: Correct error reason';
          is $result->{json}->{needs_account_selection}, undef, 'All candidates invalid: no selection is requested';
        } $current->c;
    })->then (sub {
      return $current->post(['info'], {}, session => 1)->then (sub {
        my $result = $_[0];
        test {
          is $result->{json}->{account_id}, undef;
        } $current->c;
      });
    });
  });
} n => 6, name => 'Selection Flow: All candidate accounts are invalid';

RUN;

=head1 LICENSE

Copyright 2015-2026 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
