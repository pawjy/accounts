package Accounts::Web::Handoff;
use strict;
use warnings;
use Time::HiRes qw(time);
use Digest::SHA qw(sha256 sha256_hex);
use MIME::Base64 qw(encode_base64url);
use Crypt::PRNG qw(random_bytes);
use Dongry::Type;
use JSON::PS;
use Promise;

# These records intentionally have no session_id or top-level account_id.
# They cannot be resumed as ordinary Accounts sessions.
my $Context = 'app-handoff-v1';

sub client {
  my ($class, $app, $id) = @_;
  my $clients = $app->config->get ('handoff_clients') || {};
  my $c = $clients->{$id // ''};
  return unless ref $c eq 'HASH';
  return unless ($c->{redirect_uri} // '') =~ m{\Ahttps://[a-z0-9.-]+/[A-Za-z0-9/_-]+\z};
  return unless ($c->{source_context} // '') eq 'web-login';
  return unless length ($c->{target_context} // '') and
                $c->{target_context} ne 'web-login' and
                $c->{target_context} ne $Context;
  return unless ($c->{terms_version} // '') =~ /\A[0-9]+\z/;
  return unless length ($c->{source_context}) <= 31 and length ($c->{target_context}) <= 31;
  return unless ref $c->{providers} eq 'ARRAY' and @{$c->{providers}};
  return $c;
}

# Reserve the login context only when a handoff client is configured.
sub login_context_enabled {
  my ($class, $app) = @_;
  my $clients = $app->config->get ('handoff_clients') || {};
  return scalar grep { $class->client ($app, $_) } keys %$clients;
}

sub allows_login_operation {
  my ($class, $app, $path) = @_;
  my $op = join '/', @$path;
  return defined $app->bare_param ('handoff_client') if $op eq 'login';
  return {
    session => 1, cb => 1, 'login/continue' => 1, agree => 1,
    'session/handoff/issue' => 1, 'session/handoff/redeem' => 1,
  }->{$op};
}

# Called only while starting a fresh, unauthenticated OAuth login.
sub prepare {
  my ($class, $app, $session_data, $sk_context, $provider) = @_;
  my $id = $app->bare_param ('handoff_client');
  return unless defined $id;
  my $c = $class->client ($app, $id);
  my $challenge = $app->bare_param ('handoff_challenge') // '';
  my $state = $app->bare_param ('handoff_state') // '';
  die "Invalid handoff request\n" unless $c and $session_data->{handoff_login}
      and $c->{source_context} eq $sk_context
      and $challenge =~ /\A[A-Za-z0-9_-]{43}\z/
      and $state =~ /\A[A-Za-z0-9_-]{32,128}\z/
      and grep { $_ eq $provider } @{$c->{providers} || []};
  $session_data->{handoff_request} = {
    client => $id, challenge => $challenge, state => $state,
    redirect_uri => $c->{redirect_uri}, expires => time + 600,
  };
}

sub verified {
  my ($class, $data) = @_;
  return unless $data->{handoff_request};
  my $action = $data->{action} || {};
  return unless ($action->{operation} // '') eq 'login'
      and ($action->{endpoint} // '') eq 'oauth';
  $data->{handoff_request}->{authentication} = {
    method => 'oauth', provider => $action->{server},
    login_time => $data->{login_time},
  };
}

sub invalid {
  die "Invalid handoff\n";
}

sub account {
  my ($class, $tr, $id, $c, %args) = @_;
  $class->invalid unless defined $id and "$id" =~ /\A[1-9][0-9]*\z/;
  return $tr->select ('account', {
    account_id => Dongry::Type->serialize ('text', $id),
    user_status => 1, admin_status => 1,
  }, fields => ['terms_version'], source_name => 'master', lock => 'update')->then (sub {
    my $account = $_[0]->first;
    $class->invalid unless $account;
    if ($account->{terms_version} < $c->{terms_version}) {
      die "Handoff agreement required\n" if $args{issuing};
      $class->invalid;
    }
  });
}

sub main {
  my ($class, $app, $operation) = @_;
  $app->requires_request_method ({POST => 1});
  $app->requires_api_key;
  $app->http->set_response_header ('Cache-Control' => 'no-store');
  return $app->send_error (404) unless $operation eq 'issue' or $operation eq 'redeem';
  my $tr;
  return $app->db->transaction->then (sub {
    $tr = $_[0];
    return $operation eq 'issue' ? $class->issue ($app, $tr) : $class->redeem ($app, $tr);
  })->then (sub {
    my $result = $_[0];
    return $tr->commit->then (sub { $app->send_json ($result) });
  })->catch (sub {
    # Never return DB errors, source session keys, or proof material.
    my $agreement = "$_[0]" eq "Handoff agreement required\n";
    warn "Handoff operation failed\n" unless $agreement or "$_[0]" eq "Invalid handoff\n";
    return (defined $tr ? $tr->rollback : Promise->resolve)->then (sub {
      return $app->send_error_json ({reason => 'Handoff agreement required', needs_agreement => 1}) if $agreement;
      return $app->send_error_json ({reason => 'Invalid or expired handoff'});
    });
  });
}

sub issue {
  my ($class, $app, $tr) = @_;
  my $raw = $app->bare_param ('client_info');
  $class->invalid unless defined $raw and length $raw <= 1024;
  my $info = eval { json_bytes2perl $raw };
  $class->invalid unless ref $info eq 'HASH';
  # resume_session uses SELECT ... FOR UPDATE on this transaction.  Keep
  # that lock until both the consumed request and new grant are committed.
  return Accounts::Web->resume_session ($app, $tr)->then (sub {
    my $source = $_[0];
    $class->invalid unless $source;
    my $data = $source->get ('data');
    my $request = $data->{handoff_request} || {};
    my $c = $class->client ($app, $request->{client});
    my $auth = $request->{authentication};
    $class->invalid unless $c and $data->{handoff_login} and ref $auth eq 'HASH'
        and ($auth->{method} // '') eq 'oauth'
        and $c->{source_context} eq $source->get ('sk_context')
        and $c->{redirect_uri} eq ($request->{redirect_uri} // '')
        and ($request->{expires} // 0) > time
        and ($auth->{login_time} // 0) == ($data->{login_time} // -1)
        and grep { $_ eq ($auth->{provider} // '') } @{$c->{providers} || []};
    return $class->account ($tr, $data->{account_id}, $c, issuing => 1)->then (sub {
      my $code = encode_base64url random_bytes (32);
      my $now = time;
      my $expires = $now + 60;
      $expires = $source->get ('expires') if $source->get ('expires') < $expires;
      my $grant = {
        %$request, source_sk => $source->get ('sk'),
        source_session_id => $data->{session_id}, account_id => $data->{account_id},
        target_context => $c->{target_context}, client_info => $info,
      };
      # Retain only the fields used for revocation and session history.
      $data = {map { exists $data->{$_} ? ($_ => $data->{$_}) : () }
                   qw(handoff_login session_id account_id login_time no_email handoff_audit)};
      return $tr->update ('session', {data => Dongry::Type->serialize ('json', $data)}, where => {sk => $source->get ('sk')}, source_name => 'master')->then (sub {
        return $tr->insert ('session', [{
          sk => 'h1'.sha256_hex ($code).('0' x 34), sk_context => $Context,
          created => $now, expires => $expires,
          data => Dongry::Type->serialize ('json', {handoff => $grant}),
        }], source_name => 'master');
      })->then (sub {
        return {code => $code, state => $request->{state}, redirect_uri => $c->{redirect_uri}};
      });
    });
  });
}

sub redeem {
  my ($class, $app, $tr) = @_;
  my $id = $app->bare_param ('client_id');
  my $c = $class->client ($app, $id);
  my $code = $app->bare_param ('code') // '';
  my $verifier = $app->bare_param ('code_verifier') // '';
  $class->invalid unless $c and $code =~ /\A[A-Za-z0-9_-]{43}\z/
      and $verifier =~ /\A[A-Za-z0-9._~-]{43,128}\z/
      and ($app->bare_param ('sk_context') // '') eq $c->{source_context};
  my $key = 'h1'.sha256_hex ($code).('0' x 34);
  return $tr->select ('session', {
    sk => $key, sk_context => $Context, expires => {'>', time},
  }, source_name => 'master', lock => 'update')->then (sub {
    my $row = $_[0]->first_as_row;
    $class->invalid unless $row;
    my $g = $row->get ('data')->{handoff} || {};
    $class->invalid unless ($g->{client} // '') eq $id
        and ref $g->{client_info} eq 'HASH'
        and ($g->{target_context} // '') eq $c->{target_context}
        and ($g->{redirect_uri} // '') eq $c->{redirect_uri}
        and ($g->{challenge} // '') eq encode_base64url (sha256 ($verifier))
        and ref $g->{authentication} eq 'HASH'
        and ($g->{authentication}->{method} // '') eq 'oauth'
        and grep { $_ eq ($g->{authentication}->{provider} // '') } @{$c->{providers}};
    return $tr->select ('session', {
      sk => $g->{source_sk}, sk_context => $c->{source_context}, expires => {'>', time},
    }, source_name => 'master', lock => 'update')->then (sub {
      my $source = $_[0]->first_as_row;
      $class->invalid unless $source;
      my $d = $source->get ('data');
      $class->invalid unless $d->{handoff_login}
          and ($d->{session_id} // '') eq ($g->{source_session_id} // '')
          and ($d->{account_id} // '') eq ($g->{account_id} // '')
          and ($d->{login_time} // -1) == ($g->{authentication}->{login_time} // 0);
      my $audit = {
        source_operation => 'session/handoff',
        login_method => $g->{authentication}->{method},
        service_name => $g->{authentication}->{provider},
        source_session_id => $g->{source_session_id},
        client_info => $g->{client_info},
      };
      return $class->account ($tr, $g->{account_id}, $c)->then (sub {
        return Accounts::Web->create_session ($app, $tr,
          sk_context => $c->{target_context}, sk => unpack ('H*', random_bytes (50)),
          data => {account_id => $g->{account_id}, login_time => $g->{authentication}->{login_time},
                   handoff_audit => $audit, ($d->{no_email} ? (no_email => 1) : ())});
      })->then (sub {
        my $session = $_[0];
        return Accounts::Web->write_session_log ($app, $session, time, force => 1, db => $tr)->then (sub {
          return $tr->delete ('session', {sk => $key, sk_context => $Context}, source_name => 'master');
        })->then (sub {
          return {sk => $session->get ('sk'), sk_expires => $session->get ('expires'), set_sk => 1};
        });
      });
    });
  });
}
1;
