use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Digest::SHA qw(sha1_hex);

Test {
  my $current = shift;
  my $addr = 'test@example.com';
  my $ip = '127.0.0.1';

  return $current->create (
    [s1 => session => {account => 1}],
  )->then (sub {
    return $current->post (['email', 'input'], {addr => $addr}, session => 's1');
  })->then (sub {
    return $current->post (['email', 'verify'], {key => $_[0]->{json}->{key}}, session => 's1');
  })->then (sub {
    ## Validation errors (Expected 400 or 401)
    return $current->are_errors ([['login', 'email', 'request'], {addr => $addr, source_ipaddr => $ip}, session => 's1'], [
      {params => {addr => ''}, status => 400, reason => 'Bad email address', name => 'empty addr'},
      {params => {addr => 'invalid-email'}, status => 400, reason => 'Bad email address', name => 'invalid addr format'},
      {params => {addr => "テスト\@example.com"}, status => 400, reason => 'Bad email address', name => 'non-ASCII addr'},
      {bearer => 'invalid', status => 401, name => 'invalid bearer'},
      {session => undef, status => 400, reason => 'Bad session', name => 'no session'},
      {method => 'GET', status => 405, name => 'GET request'},
    ]);
  })->then (sub {
    ## Verification errors (Expected 400)
    return $current->are_errors ([['login', 'email', 'verify'], {addr => $addr, secret_number => '12345678', source_ipaddr => $ip}, session => 's1'], [
      {params => {addr => ''}, status => 400, reason => 'Invalid secret number', name => 'empty addr'},
      {params => {secret_number => ''}, status => 400, reason => 'Invalid secret number', name => 'empty secret'},
      {params => {secret_number => 'abc'}, status => 400, reason => 'Invalid secret number', name => 'non-numeric secret'},
      {bearer => 'invalid', status => 401, name => 'invalid bearer'},
      {session => undef, status => 400, reason => 'Bad session', name => 'no session'},
      {method => 'GET', status => 405, name => 'GET request'},
    ]);
  });
} n => 2, name => 'Validation and session errors';

Test {
  my $current = shift;
  my $addr = 'log1@example.com';
  my $ip = '127.0.0.2';
  my $ua = 'TestAgent/1.0';
  my $secret;
  my $account_id;

  return $current->create (
    [s1 => session => {account => 1}],
  )->then (sub {
    $account_id = $current->o ('s1')->{account}->{account_id};
    return $current->post (['email', 'input'], {addr => $addr}, session => 's1');
  })->then (sub {
    return $current->post (['email', 'verify'], {key => $_[0]->{json}->{key}}, session => 's1');
  })->then (sub {
    ## 1. Request
    return $current->post (['login', 'email', 'request'], {
      addr => $addr, source_ipaddr => $ip, source_ua => $ua,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    $secret = $result->{json}->{secret_number};
    test {
      is $result->{json}->{should_send_email}, 1, 'should send email';
      ok time < $result->{json}->{secret_expires}, $result->{json}->{secret_expires};
      ok $secret, 'has secret';
    } $current->c;

    ## 2. Check request log
    return $current->post (['log', 'get'], {action => 'login/email/request'});
  })->then (sub {
    my $result = $_[0];
    my $items = $result->{json}->{items};
    my $log = (grep { $_->{data}->{linked_email} eq $addr } @$items)[0];
    test {
      ok $log, 'request log exists';
      is $log->{account_id}, $account_id, 'log has correct account_id';
      is $log->{ipaddr}, $ip, 'log has correct ipaddr';
      is $log->{ua}, $ua, 'log has correct ua';
      is $log->{data}->{result}, 'sent', 'log result is sent';
      is $log->{data}->{linked_email}, $addr, 'log data has email';
    } $current->c;

    ## 3. Verify success
    return $current->post (['login', 'email', 'verify'], {
      addr => $addr, secret_number => $secret, source_ipaddr => $ip, source_ua => $ua,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200, 'verify success';
      ok $result->{json}->{lk}, 'lk is returned';
      is $result->{json}->{account_id}, $account_id, 'account_id matches';
      like $result->{res}->body_bytes, qr{"account_id":"}, 'account_id is a string';
    } $current->c;

    ## 4. Verify with /info
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{account_id}, $account_id, 'info returns correct account_id';
    } $current->c;

    ## 5. Check verify logs
    return $current->post (['log', 'get'], {action => 'login/email/verify'});
  })->then (sub {
    my $result = $_[0];
    my $items = $result->{json}->{items};
    my $log = (grep { $_->{data}->{linked_email} eq $addr } @$items)[0];
    test {
      ok $log, 'verify log exists';
      is $log->{account_id}, $account_id, 'verify log has correct account_id';
      is $log->{ipaddr}, $ip, 'verify log has correct ipaddr';
      is $log->{ua}, $ua, 'verify log has correct ua';
      is $log->{data}->{result}, 'success', 'verify log result is success';
      is $log->{data}->{linked_email}, $addr, 'verify log data has email';
    } $current->c;
  });
} n => 20, name => 'Basic success flow and comprehensive log check';

Test {
  my $current = shift;
  my $addr = 'log2@example.com';
  my $ip = '127.0.0.2';
  my $ua = 'TestAgent/1.0';
  my $secret;
  my $account_id;

  return $current->create (
    [s1 => session => {account => 1}],
  )->then (sub {
    $account_id = $current->o ('s1')->{account}->{account_id};
    return $current->post (['email', 'input'], {addr => $addr}, session => 's1');
  })->then (sub {
    return $current->post (['email', 'verify'], {key => $_[0]->{json}->{key}}, session => 's1');
  })->then (sub {
    ## 1. Request
    return $current->post (['login', 'email', 'request'], {
      addr => $addr, source_ipaddr => $ip, source_ua => $ua,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    $secret = $result->{json}->{secret_number};
    test {
      is $result->{json}->{should_send_email}, 1, 'should send email';
      ok time < $result->{json}->{secret_expires}, $result->{json}->{secret_expires};
      ok $secret, 'has secret';
    } $current->c;

    ## 2. Check request log
    return $current->post (['log', 'get'], {action => 'login/email/request'});
  })->then (sub {
    my $result = $_[0];
    my $items = $result->{json}->{items};
    my $log = (grep { $_->{data}->{linked_email} eq $addr } @$items)[0];
    test {
      ok $log, 'request log exists';
      is $log->{account_id}, $account_id, 'log has correct account_id';
      is $log->{ipaddr}, $ip, 'log has correct ipaddr';
      is $log->{ua}, $ua, 'log has correct ua';
      is $log->{data}->{result}, 'sent', 'log result is sent';
      is $log->{data}->{linked_email}, $addr, 'log data has email';
    } $current->c;

    return $current->post (['login', 'email', 'verify'], {
      addr => $addr, secret_number => $secret . 1,
      source_ipaddr => $ip, source_ua => $ua,
    }, session => 's1');
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{lk}, undef;
      is $result->{json}->{account_id}, undef;
    } $current->c;

    return $current->post (['login', 'email', 'verify'], {
      addr => $addr, secret_number => $secret . 2,
      source_ipaddr => $ip, source_ua => $ua,
    }, session => 's1');
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{lk}, undef;
      is $result->{json}->{account_id}, undef;
    } $current->c;

    return $current->post (['login', 'email', 'verify'], {
      addr => $addr, secret_number => $secret . 3,
      source_ipaddr => $ip, source_ua => $ua,
    }, session => 's1');
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400;
      is $result->{json}->{lk}, undef;
      is $result->{json}->{account_id}, undef;
    } $current->c;
  })->then (sub {
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{account_id}, $account_id, 'info returns correct account_id';
    } $current->c;

    return $current->post (['log', 'get'], {action => 'login/email/verify'});
  })->then (sub {
    my $result = $_[0];
    my $items = $result->{json}->{items};
    my $logs = [grep { $_->{data}->{linked_email} eq $addr } @$items];
    test {
      is 0+@$logs, 3;
      {
        my $log = $logs->[2];
        is $log->{account_id}, 0;
        is $log->{ipaddr}, $ip, 'verify log has correct ipaddr';
        is $log->{ua}, $ua, 'verify log has correct ua';
        is $log->{data}->{result}, 'failed';
        is $log->{data}->{linked_email}, $addr, 'verify log data has email';
      }
      {
        my $log = $logs->[1];
        is $log->{account_id}, 0;
        is $log->{ipaddr}, $ip, 'verify log has correct ipaddr';
        is $log->{ua}, $ua, 'verify log has correct ua';
        is $log->{data}->{result}, 'failed';
        is $log->{data}->{linked_email}, $addr, 'verify log data has email';
      }
      {
        my $log = $logs->[0];
        is $log->{account_id}, 0;
        is $log->{ipaddr}, $ip, 'verify log has correct ipaddr';
        is $log->{ua}, $ua, 'verify log has correct ua';
        is $log->{data}->{result}, 'too_many_attempts';
        is $log->{data}->{linked_email}, $addr, 'verify log data has email';
      }
    } $current->c;
  });
} n => 35, name => 'Bad secret number attempts';

Test {
  my $current = shift;
  my $addr = 'notfound@example.com';
  my $ip = '127.0.0.3';
  my $ua = 'NotFoundAgent/1.0';

  return $current->create (
    [s1 => session => {}],
  )->then (sub {
    return $current->post (['login', 'email', 'request'], {
      addr => $addr, source_ipaddr => $ip, source_ua => $ua,
    }, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{should_send_email}, 0, 'should not send email';
      is $result->{json}->{secret_number}, undef;
      is $result->{json}->{secret_expires}, undef;
    } $current->c;

    ## Check log for not_found
    return $current->post (['log', 'get'], {action => 'login/email/request'});
  })->then (sub {
    my $result = $_[0];
    my $items = $result->{json}->{items};
    my $log = (grep { $_->{data}->{linked_email} eq $addr } @$items)[0];
    test {
      ok $log, 'request log exists for notfound';
      is $log->{account_id}, 0, 'log account_id is 0 for notfound';
      is $log->{data}->{result}, 'not_found', 'log result is not_found';
      is $log->{ipaddr}, $ip, 'log has correct ipaddr';
      is $log->{ua}, $ua, 'log has correct ua';
    } $current->c;
  });
} n => 8, name => 'Uniform response and not_found log';

Test {
  my $current = shift;
  my $addr = 'multi@example.com';
  my $ip = '127.0.0.4';
  my ($s1, $s2, $a1, $a2, $secret);

  return $current->create (
    [s1 => session => {account => 1}],
    [s2 => session => {account => 1}],
  )->then (sub {
    $a1 = $current->o ('s1')->{account}->{account_id};
    $a2 = $current->o ('s2')->{account}->{account_id};
    
    ## Link accounts
    return $current->post (['email', 'input'], {addr => $addr}, session => 's1');
  })->then (sub {
    return $current->post (['email', 'verify'], {key => $_[0]->{json}->{key}}, session => 's1');
  })->then (sub {
    return $current->post (['email', 'input'], {addr => $addr}, session => 's2');
  })->then (sub {
    return $current->post (['email', 'verify'], {key => $_[0]->{json}->{key}}, session => 's2');
  })->then (sub {
    ## Request
    return $current->post (['login', 'email', 'request'], {addr => $addr, source_ipaddr => $ip}, session => 's1');
  })->then (sub {
    $secret = $_[0]->{json}->{secret_number};
    ## Verify
    return $current->post (['login', 'email', 'verify'], {addr => $addr, secret_number => $secret, source_ipaddr => $ip}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      ok $result->{json}->{needs_account_selection}, 'multiple accounts found';
      is scalar @{$result->{json}->{accounts}}, 2, 'two account choices';
    } $current->c;
    
    ## 1. Continue with first account
    return $current->post (['login', 'continue'], {selected_account_id => $a1}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200, 'continue success';
      is $result->{json}->{account_id}, $a1, 'account_id matches a1';
      like $result->{res}->body_bytes, qr{"account_id":"};
    } $current->c;

    ## 2. Check /info
    return $current->post (['info'], {}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{account_id}, $a1, 'info returns a1';
    } $current->c;
  });
} n => 6, name => 'Multiple accounts and continue';

Test {
  my $current = shift;
  my $addr = 'rate-email@example.com';
  
  return $current->create (
    [s1 => session => {account => 1}],
  )->then (sub {
    return $current->post (['email', 'input'], {addr => $addr}, session => 's1');
  })->then (sub {
    return $current->post (['email', 'verify'], {key => $_[0]->{json}->{key}}, session => 's1');
  })->then (sub {
    ## Request 2 times from DIFFERENT IPs (Limit is 2 for email)
    my $p = Promise->resolve;
    for (1..2) {
      my $req_ip = '192.168.10.' . $_;
      $p = $p->then (sub {
        return $current->post (['login', 'email', 'request'], {addr => $addr, source_ipaddr => $req_ip}, session => 's1');
      })->then (sub {
        my $result = $_[0];
        test {
          is $result->{json}->{should_send_email}, 1, 'request allowed';
        } $current->c;
      });
    }
    return $p;
  })->then (sub {
    ## 3rd request should be rate limited by EMAIL (even from a new IP)
    return $current->post (['login', 'email', 'request'], {addr => $addr, source_ipaddr => '192.168.10.100'}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{should_send_email}, 0, 'rate limited by email';
    } $current->c;

    ## Check log for email rate_limited
    return $current->post (['log', 'get'], {action => 'login/email/request'});
  })->then (sub {
    my $result = $_[0];
    my $items = $result->{json}->{items};
    # Find the latest log for this email that is rate_limited
    my $log = (grep { $_->{data}->{linked_email} eq $addr and $_->{data}->{result} eq 'rate_limited' } @$items)[0];
    test {
      ok $log, 'log exists for email rate_limited';
      is $log->{data}->{result}, 'rate_limited', 'log result is rate_limited';
      is $log->{data}->{reason}, 'Email rate limit', 'log reason is correct';
    } $current->c;
  });
} n => 6, name => 'Email rate limit and comprehensive log check';

Test {
  my $current = shift;
  my $addr = 'rate-ip@example.com';
  my $ip = '127.0.0.5';
  
  return $current->create (
    [s1 => session => {}],
  )->then (sub {
    ## Request 3 times (Limit is 3 for IP in RUN block below)
    my $p = Promise->resolve;
    for (1..3) {
      $p = $p->then (sub {
        return $current->post (['login', 'email', 'request'], {addr => 'random' . (rand 1000) . '@example.com', source_ipaddr => $ip}, session => 's1');
      });
    }
    return $p;
  })->then (sub {
    ## 4th request should be rate limited by IP
    return $current->post (['login', 'email', 'request'], {addr => 'another@example.com', source_ipaddr => $ip}, session => 's1');
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{json}->{should_send_email}, 0, 'rate limited by IP';
    } $current->c;

    ## Check log for IP rate_limited
    return $current->post (['log', 'get'], {action => 'login/email/request'});
  })->then (sub {
    my $result = $_[0];
    my $items = $result->{json}->{items};
    my $log = (grep { $_->{data}->{result} eq 'rate_limited' and $_->{data}->{reason} eq 'IP rate limit' and $_->{ipaddr} eq $ip } @$items)[0];
    test {
      ok $log, 'log exists for IP rate_limited';
      is $log->{data}->{result}, 'rate_limited', 'log result is rate_limited';
      is $log->{data}->{reason}, 'IP rate limit', 'log reason is correct';
    } $current->c;
  });
} n => 4, name => 'IP rate limit and comprehensive log check';

Test {
  my $current = shift;
  my $addr = 'mix@example.com';
  my ($s1, $s2, $s3, $a1, $a2, $secret);

  return $current->create (
    [s1 => session => {account => 1}],
    [s2 => session => {account => 1}],
    [s3 => session => {}],
  )->then (sub {
    $a1 = $current->o ('s1')->{account}->{account_id};
    $a2 = $current->o ('s2')->{account}->{account_id};
    
    ## Link accounts to email
    return $current->post (['email', 'input'], {addr => $addr}, session => 's1');
  })->then (sub {
    return $current->post (['email', 'verify'], {key => $_[0]->{json}->{key}}, session => 's1');
  })->then (sub {
    return $current->post (['email', 'input'], {addr => $addr}, session => 's2');
  })->then (sub {
    return $current->post (['email', 'verify'], {key => $_[0]->{json}->{key}}, session => 's2');
  })->then (sub {
    ## 1. Start Email Login with s3
    return $current->post (['login', 'email', 'request'], {addr => $addr}, session => 's3');
  })->then (sub {
    $secret = $_[0]->{json}->{secret_number};
    return $current->post (['login', 'email', 'verify'], {addr => $addr, secret_number => $secret}, session => 's3');
  })->then (sub {
    my $result = $_[0];
    test {
      ok $result->{json}->{needs_account_selection}, 'multiple accounts found';
    } $current->c;
    ## 2. Overwrite with OAuth Login start (use 'github' which is configured)
    return $current->post (['login'], {server => 'github', callback_url => 'http://example.com/cb'}, session => 's3');
  })->then (sub {
    ## 3. Try to continue as Email Login (should fail because action was overwritten by OAuth)
    return $current->post (['login', 'continue'], {selected_account_id => $a1}, session => 's3');
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400, 'overwritten flow fails';
      ok $result->{json}->{reason}, 'has error reason';
    } $current->c;
  });
} n => 3, name => 'Mixed flow state';

Test {
  my $current = shift;
  my $addr = 'order@example.com';
  
  return $current->create (
    [s1 => session => {}],
  )->then (sub {
    ## 1. Continue before any login flow
    return $current->post (['login', 'continue'], {selected_account_id => '123'}, session => 's1');
  })->then (sub { test { ok 0 } $current->c }, sub {
    my $result = $_[0];
    test {
      is $result->{status}, 400, 'continue before flow fails';
      is $result->{json}->{reason}, 'Bad login flow state';
    } $current->c;
  });
} n => 2, name => 'Improper order / empty flow';

RUN (
  additional_app_config => {
    login_email_rate_limit_ip_count => 3,
    login_email_rate_limit_ip_window => 600,
    login_email_rate_limit_email_count => 2,
    login_email_rate_limit_email_window => 3600,
    login_email_attempts_limit_count => 2,
    'github.client_id' => 'abc',
    'github.client_secret' => 'def',
  },
);

=head1 LICENSE

Copyright 2015-2026 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
