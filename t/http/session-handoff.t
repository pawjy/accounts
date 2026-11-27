use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;
use Promised::Command;
use Digest::SHA qw(sha256);
use MIME::Base64 qw(encode_base64url);

my $client = 'iphone';
my $redirect = 'https://login.example.test/account/app/return';

for my $operation (qw(issue redeem)) {
  Test {
    my $current = shift;
    return $current->are_errors (
      [['session', 'handoff', $operation], {sk_context => 'web-login'}],
      [{method => 'GET', status => 405}, {bearer => undef, status => 401},
       {status => 400, reason => 'Invalid or expired handoff'}],
    );
  } n => 1, name => "/session/handoff/$operation request requirements";
}

Test {
  my $current = shift;
  my $state = 'a' x 43;
  my $verifier = 'b' x 43;
  my $login = {sk_context => 'web-login'};
  my ($code, $session, $account_id);
  my $issue = sub {
    return $current->post (['session', 'handoff', 'issue'], {
      %$login, client_info => perl2json_bytes ({platform => 'ios'}),
    });
  };
  my $redeem = sub {
    return $current->post (['session', 'handoff', 'redeem'], {
      sk_context => 'web-login', client_id => $client,
      code => $code, code_verifier => $verifier,
    });
  };
  return $current->post (['session'], $login)->then (sub {
    my $json = $_[0]->{json};
    $login->{sk} = $json->{sk};
    test {
      ok $json->{sk_expires} > time;
      ok $json->{sk_expires} <= time + 600;
    } $current->c;
    my $params = {
      %$login, server => 'oauth2server', callback_url => 'https://app.example.test/cb',
      handoff_client => $client, handoff_challenge => encode_base64url (sha256 $verifier),
      handoff_state => $state,
    };
    return $current->are_errors (
      [['login'], $params],
      [map { +{params => {%$params, %$_}, status => 400} }
           {handoff_challenge => 'short'}, {handoff_state => ''}, {handoff_client => 'unknown'}],
    )->then (sub { return $current->post (['login'], $params) });
  })->then (sub {
    my $url = Web::URL->parse_string ($_[0]->{json}->{authorization_url});
    return $current->are_errors (
      [['session', 'handoff', 'issue'], {%$login, client_info => '{}'}],
      [{status => 400}],
    )->then (sub {
      return $current->client_for ($url)->request (url => $url, method => 'POST',
          params => {account_id => $current->generate_id (id => {})});
    });
  })->then (sub {
    my $res = $_[0];
    test { is $res->status, 302 } $current->c;
    my (undef, $query) = split /\?/, $res->header ('Location'), 2;
    return $current->post ("/cb?$query", $login);
  })->then (sub {
    my $json = $_[0]->{json};
    $account_id = $json->{account_id};
    test { ok $json->{has_handoff}; like $account_id, qr{\A[1-9][0-9]*\z} } $current->c;
    return $current->are_errors (
      [['info'], $login], [{status => 400, reason => 'Operation unavailable in login context'}],
    );
  })->then (sub {
    return $current->post (['agree'], {%$login, version => 2});
  })->then ($issue)->then (sub {
    my $json = $_[0]->{json};
    $code = $json->{code};
    test {
      is $json->{redirect_uri}, $redirect;
      is $json->{state}, $state;
      like $code, qr{\A[A-Za-z0-9_-]{43}\z};
    } $current->c;
    return $redeem->();
  })->then (sub {
    $session = {sk_context => 'web', sk => $_[0]->{json}->{sk}};
    test { isnt $session->{sk}, $login->{sk} } $current->c;
    return $current->post (['info'], $session);
  })->then (sub {
    my $json = $_[0]->{json};
    test { is $json->{account_id}, $account_id } $current->c;
    return $current->post (['session', 'get'], {%$session, use_sk => 1});
  })->then (sub {
    my %history = map { $_->{sk_context} => $_ } @{$_[0]->{json}->{items}};
    my $source = $history{'web-login'};
    my $target = $history{web};
    test {
      is $source->{log_data}->{login_method}, 'oauth';
      is $target->{log_data}->{source_session_id}, $source->{session_id};
      isnt $target->{session_id}, $source->{session_id};
      is $target->{log_data}->{service_name}, 'oauth2server';
      is_deeply $target->{log_data}->{client_info}, {platform => 'ios'};
    } $current->c;
    return $current->are_errors (
      [['session', 'handoff', 'redeem'], {sk_context => 'web-login', client_id => $client,
                                          code => $code, code_verifier => $verifier}],
      [{status => 400}],
    );
  });
} n => 19, name => 'OAuth callback, agreement, handoff and ordinary Web session';

Test {
  my $current = shift;
  my $fixture = $current->{servers_data};
  my $cmd = Promised::Command->new ([
    'python3', path (__FILE__)->absolute->parent->parent->parent->child ('t_deps/handoff-integration.py'),
  ]);
  my $db = {%{$fixture->{test_db}}};
  $db->{host} = $db->{host}->to_ascii if ref $db->{host};
  $cmd->envs->{HANDOFF_TEST_DB} = perl2json_bytes $db;
  $cmd->envs->{HANDOFF_TEST_ORIGIN} = $fixture->{app_local_url}->get_origin->to_ascii;
  $cmd->envs->{HANDOFF_TEST_BEARER} = $fixture->{app_bearer};
  return $cmd->run->then (sub { return $cmd->wait })->then (sub {
    my $result = $_[0];
    test { is $result->exit_code, 0, 'HTTP and database invariants' } $current->c;
  });
} n => 1, timeout => 180, name => 'Handoff locking, rollback and lifetime';

RUN additional_app_config => {
  handoff_clients => {$client => {
    source_context => 'web-login', target_context => 'web', providers => ['oauth2server', 'google'],
    terms_version => 2, redirect_uri => $redirect,
  }},
};
