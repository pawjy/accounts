use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Web::URL;

sub setup_multiple_linked_accounts {
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
      my $service_name = $current->o('server_type');

      return Promise->all([
          $current->post(['link', 'add'], {
              server => $service_name,
              linked_id => $x_account_id,
          }, session => 2), # As Account A
          $current->post(['link', 'add'], {
              server => $service_name,
              linked_id => $x_account_id,
          }, session => 3), # As Account B
      ]);
  });

  return $setup_promise->then(sub { return { 
    cb_url => $cb_url, x_account_id => $x_account_id, 
    account_id_A => $account_id_A, account_id_B => $account_id_B 
  } });
}

for my $server_type (qw(oauth1server oauth2server)) {
  Test {
    my $current = shift;
    $current->set_o (server_type => $server_type);
    my $o;

    return $current->create_browser (1 => {})->then(sub{
      return setup_multiple_linked_accounts($current);
    })->then (sub {
      $o = $_[0];
      return $current->b_go_cs (1 => qq</start?select_account_on_multiple=1&server=> . $server_type);
    })->then (sub {
        my $x_account_id = $o->{x_account_id};
        return $current->b (1)->execute (q{
          var input = document.createElement ('input');
          input.type = 'hidden';
          input.name = 'account_id';
          input.value = arguments[0];
          document.querySelector ('form').appendChild (input);
          setTimeout (() => {
            document.querySelector ('form [type=submit]').click ();
          }, 100);
        }, [$x_account_id]);
    })->then (sub {
      return promised_wait_until {
        return $current->b (1)->execute (q{
          return document.querySelector('[data-account-id]')
        })->then (sub {
          return $_[0]->json->{value};
        });
      } timeout => 34;
    })->then(sub {
      test { ok 1, 'Browser is now in account selection state' } $current->c;
    })->then (sub {
      my $account_id_B = $o->{account_id_B};
        return $current->b(1)->execute(q{
            const accountId = arguments[0];
            console.log("Clicking account", accountId);
            document.querySelector(`[data-account-id="${accountId}"]`).click();
        }, [$account_id_B]);
    })->then(sub {
      return promised_sleep 0.5;
    })->then(sub {
      return $current->b_go_cs (1 => q</info>);
    })->then(sub {
      return $current->b (1)->execute (q{ return document.body.textContent; });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->json->{value};
      test {
        is $json->{account_id}, $o->{account_id_B}, 'Logged in as the selected account (Account B)';
      } $current->c;
    });
  } n => 2, name => ['Browser E2E for account selection', $server_type], browser => 1;

}

RUN;

=head1 LICENSE

Copyright 2015-2026 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
