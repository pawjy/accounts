package Tests::Current;
use strict;
use warnings;
use Time::HiRes qw(time);
use JSON::PS;
use Web::URL;
use Web::Transport::BasicClient;
use Promised::Flow;
use Test::More;
use Test::X1;
use ServerSet::ReverseProxyProxyManager;

sub c ($) {
  return $_[0]->{context};
} # c

sub client ($) {
  my $self = $_[0];
  return $self->{client} ||= do {
    my $url = $self->{servers_data}->{app_client_url};
    $self->client_for ($url);
  };
} # client

sub client_for ($$) {
  my $self = $_[0];
  my $url = $_[1];
  return $self->{client_for}->{$url->get_origin->to_ascii} ||= do {
    my $http = Web::Transport::BasicClient->new_from_url ($url, {
      proxy_manager => ServerSet::ReverseProxyProxyManager->new_from_envs ($self->{servers_data}->{local_envs}),
    });
    $http;
  };
} # client_for

sub o ($$) {
  my ($self, $name) = @_;
  return $self->{objects}->{$name} || die "Object |$name| not found";
} # o

sub set_o ($$$) {
  my ($self, $name, $v) = @_;
  $self->{objects}->{$name} = $v;
} # set_o

my $Chars = [0x0000..0xD7FF, 0xE000..0x10FFFF];
sub generate_text ($$$) {
  my ($self, $name, $opts) = @_;
  my $length = $opts->{length} || int rand 30 || 1;
  my $bytes = '';
  $bytes .= chr $Chars->[rand @$Chars] for 1..$length;
  return $self->{objects}->{$name} = $bytes;
} # generate_text

my $KeyChars = [0x20..0x7E];
sub generate_key ($$$) {
  my ($self, $name, $opts) = @_;
  my $length = $opts->{length} || int rand 30 || 1;
  my $bytes = '';
  $bytes .= chr $KeyChars->[rand @$KeyChars] for 1..$length;
  return $self->{objects}->{$name} = $bytes;
} # generate_key

sub generate_id ($$$) {
  my ($self, $name, $opts) = @_;
  return $self->{objects}->{$name} = int rand 100000000;
} # generate_id

sub generate_domain ($$$) {
  my ($self, $name, $opts) = @_;
  my $v = rand . '.test';
  return $self->{objects}->{$name // ''} = $v;
} # generate_domain

sub generate_email_addr ($$$) {
  my ($self, $name, $opts) = @_;
  return $self->{objects}->{$name // ''} = ($opts->{prefix} // '') . rand . '@' . $self->generate_domain (rand, {});
} # generate_email_addr

sub generate_bytes ($$$) {
  my ($self, $name, $opts) = @_;
  my $length = $opts->{length} || int rand 10000 || 1;
  my $bytes = '';
  $bytes .= pack 'C', [0x00..0xFF]->[rand 256] for 1..$length;
  return $self->{objects}->{$name} = $bytes;
} # generate_bytes

sub generate_context_key ($$$) {
  my ($self, $name, $opts) = @_;
  my $length = $opts->{length} || int rand 30 || 1;
  my $bytes = '';
  $bytes .= pack 'C', [0x20..0x7E]->[rand 95] for 1..$length;
  return $self->{objects}->{$name} = $bytes;
} # generate_context_key

sub generate_timestamp ($$$) {
  my ($self, $name, $opts) = @_;
  return $self->{objects}->{$name} = time - 1000_0000 + int rand 1000_0000;
} # generate_timestamp

sub post ($$$;%) {
  my ($self, $path, $params, %args) = @_;
  my $p = {sk_context => 'tests'};
  if (defined $args{session}) {
    my $session = $self->o ($args{session});
    $p->{sk} = $session->{sk};
    $p->{sk_context} = $session->{sk_context};
  } elsif (defined $args{account}) {
    my $account = $self->o ($args{account});
    $p->{sk} = $account->{session}->{sk};
    $p->{sk_context} = $account->{session}->{sk_context};
  }
  return $self->client->request (
    method => 'POST',
    (ref $path ?
      (path => $path)
    :
      (url => Web::URL->parse_string ($path, Web::URL->parse_string ($self->client->origin->to_ascii)))
    ),
    bearer => $self->{servers_data}->{app_bearer},
    params => {%$p, %$params},
    headers => $args{headers},
  )->then (sub {
    my $res = $_[0];
    if ($res->status == 200 or $res->status == 400) {
      my $result = {res => $res,
                    status => $res->status,
                    json => json_bytes2perl $res->body_bytes};
      die $result if $res->status == 400;
      return $result;
    } elsif ($res->status == 302) {
      return $res;
    }
    die $res;
  });
} # post

sub are_errors ($$$) {
  my ($self, $base, $tests) = @_;
  my ($base_path, $base_params, %base_args) = @$base;

  my $has_error = 0;

  return (promised_for {
    my $test = shift;
    my %opt = (
      method => 'POST',
      path => $base_path,
      params => {%$base_params},
      bearer => $self->{servers_data}->{app_bearer},
      %base_args,
      %$test,
    );
    if (defined $opt{session}) {
      my $session = $self->o ($opt{session});
      $opt{params}->{sk} = $session->{sk};
      $opt{params}->{sk_context} = 'tests';
    } elsif (defined $opt{account}) {
      my $account = $self->o ($opt{account});
      $opt{params}->{sk} = $account->{session}->{sk};
      $opt{params}->{sk_context} = 'tests';
    }
    return $self->client->request (
      method => $opt{method}, path => $opt{path}, params => $opt{params},
      bearer => $opt{bearer},
    )->then (sub {
      my $res = $_[0];
      unless ($opt{status} == $res->status) {
        test {
          is $res->status, $opt{status}, "$res (status)";
        } $self->c, name => $opt{name};
        $has_error = 1;
      }
      if (defined $opt{reason}) {
        my $json = json_bytes2perl $res->body_bytes;
        unless (defined $json and
                ref $json eq 'HASH' and
                defined $json->{reason} and
                $json->{reason} eq $opt{reason}) {
          test {
            is $json->{reason}, $opt{reason}, "$res (reason)";
          } $self->c, name => $opt{name};
          $has_error = 1;
        }
      }
    });
  } $tests)->then (sub {
    test {
      ok !$has_error, 'are_errors: no error';
    } $self->c;
  });
} # are_errors

sub pages_ok ($$$$;$%) {
  my $self = $_[0];
  my ($path, $params, %args) = @{$_[1]};
  my $items = [@{$_[2]}];
  my $field = $_[3];
  my $name = $_[4];
  my %opts = @_[5..$#_];
  my $count = int (@$items / 2) + 3;
  my $page = 1;
  my $ref;
  my $has_error = 0;
  return promised_cleanup {
    return if $has_error;
    note "no error (@{[$page-1]} pages)";
    return $self->are_errors (
      [$path, $params, %args],
      [
        {params => {%$params, ref => rand}, name => 'Bad |ref|', status => 400},
        {params => {%$params, ref => '+5353,350000'}, name => 'Bad |ref| offset', status => 400},
        {params => {%$params, limit => 40000}, name => 'Bad |limit|', status => 400},
      ],
      $name,
    );
  } promised_wait_until {
    return $self->post ($path, {%$params, limit => 2, ref => $ref}, %args)->then (sub {
      my $result = $_[0];
      my $expected_length = (@$items > 2 ? 2 : 0+@$items);
      $result->{json}->{items} = ($opts{items} or sub { $_[0] })->($result->{json}->{items});
      my $actual_length = 0+@{$result->{json}->{items}};
      if ($expected_length == $actual_length) {
        if ($expected_length >= 1) {
          unless ($result->{json}->{items}->[0]->{$field} eq $self->o ($items->[-1])->{$field}) {
            test {
              is $result->{json}->{items}->[0]->{$field},
                 $self->o ($items->[-1])->{$field}, "page $page, first item";
            } $self->c, name => $name;
            $count = 0;
            $has_error = 1;
          }
        }
        if ($expected_length >= 2) {
          unless ($result->{json}->{items}->[1]->{$field} eq $self->o ($items->[-2])->{$field}) {
            test {
              is $result->{json}->{items}->[1]->{$field},
                 $self->o ($items->[-2])->{$field}, "page $page, second item";
            } $self->c, name => $name;
            $count = 0;
            $has_error = 1;
          }
        }
        pop @$items;
        pop @$items;
      } else {
        test {
          is $actual_length, $expected_length, "page $page length";
        } $self->c, name => $name;
        $count = 0;
        $has_error = 1;
      }
      if (@$items) {
        unless ($result->{json}->{has_next} and
                defined $result->{json}->{next_ref}) {
          test {
            ok $result->{json}->{has_next}, 'has_next';
            ok $result->{json}->{next_ref}, 'next_ref';
          } $self->c, name => $name;
          $count = 0;
          $has_error = 1;
        }
      } else {
        if ($result->{json}->{has_next}) {
          test {
            ok ! $result->{json}->{has_next}, 'no has_next';
          } $self->c, name => $name;
          $count = 0;
          $has_error = 1;
        }
      }
      $ref = $result->{json}->{next_ref};
    })->then (sub {
      $page++;
      return not $count >= $page;
    });
  };
} # pages_ok

sub create ($;@) {
  my $self = shift;
  return promised_for {
    my ($name, $type, $opts) = @{$_[0]};
    my $method = 'create_' . $type;
    return $self->$method ($name => $opts);
  } [@_];
} # create

sub create_session ($$$) {
  my ($self, $name, $opts) = @_;
  my $session;
  my $skc = $opts->{sk_context} // 'tests';
  return $self->post (['session'], {
    sk_context => $skc,
    source_ua => $opts->{source_ua},
    source_ipaddr => $opts->{source_ipaddr},
  })->then (sub {
    $session = $self->{objects}->{$name} = $_[0]->{json};
    $session->{sk_context} = $skc;
    
    if ($opts->{account}) {
      return $self->post (['create'], {
        sk_context => $session->{sk_context},
        sk => $session->{sk},
        name => $self->generate_text (rand, {}),
        #user_status
        #admin_status
        source_ua => $opts->{source_ua},
        source_ipaddr => $opts->{source_ipaddr},
      })->then (sub {
        $session->{account} = $_[0]->{json};
      });
    }
  })->then (sub {
    return unless $opts->{session_id};
    return $self->post (['session', 'get'], {
      use_sk => 1,
      sk_context => $session->{sk_context},
      sk => $session->{sk},
    })->then (sub {
      my $result = $_[0];
      $session->{session_id} = $result->{json}->{items}->[0]->{session_id};
    });
  });
} # create_session

sub create_account ($$$) {
  my ($self, $name, $opts) = @_;
  my $session;
  my $skc = $opts->{sk_context} // 'tests';
  return $self->post (['session'], {
    sk_context => $skc,
  })->then (sub {
    my $result = $_[0];
    $session = $result->{json};
    $session->{sk_context} = $skc;
    return $self->post (['create'], {
      sk => $session->{sk},
      sk_context => $session->{sk_context},
      name => $opts->{name},
      login_time => $opts->{login_time},
    });
  })->then (sub {
    my $result = $_[0];
    $result->{json}->{session} = $session;
    $self->{objects}->{$name} = $result->{json}; # {account_id => }
    my $names = [];
    my $values = [];
    for (keys %{$opts->{data} or {}}) {
      push @$names, $_;
      push @$values, $opts->{data}->{$_};
    }
    return unless @$names;
    return $self->post (['data'], {
      sk => $session->{sk},
      sk_context => $session->{sk_context},
      name => $names,
      value => $values,
    })->then (sub {
      my $result = $_[0];
      die $result unless $result->{status} == 200;
    });
  });
} # create_account

sub create_group ($$$) {
  my ($self, $name => $opts) = @_;
  $opts->{context_key} //= rand;
  my $group_id;
  return $self->post (['group', 'create'], $opts)->then (sub {
    my $result = $_[0];
    die $result unless $result->{status} == 200;
    $self->{objects}->{$name} = $result->{json}; # {context_key, group_id}
    $group_id = $result->{json}->{group_id};
    my $names = [];
    my $values = [];
    for (keys %{$opts->{data} or {}}) {
      push @$names, $_;
      push @$values, $opts->{data}->{$_};
    }
    return unless @$names;
    return $self->post (['group', 'data'], {
      context_key => $opts->{context_key},
      group_id => $group_id,
      name => $names,
      value => $values,
    })->then (sub {
      my $result = $_[0];
      die $result unless $result->{status} == 200;
    });
  })->then (sub {
    my $members = [map {
      $_->{account_id} = $self->o (delete $_->{account})->{account_id}
          if defined $_->{account};
      $_;
    } map {
      if (ref $_) {
        $_;
      } else {
        +{account => $_,
          user_status => 1,
          owner_status => 1,
          member_type => 1};
      }
    } @{$opts->{members} or []}];
    return promised_for {
      my $account = $_[0];
      return $self->post (['group', 'member', 'status'], {
        context_key => $opts->{context_key},
        group_id => $group_id,
        %$account,
      })->then (sub {
        my $names = [];
        my $values = [];
        for (keys %{$account->{data} or {}}) {
          push @$names, $_;
          push @$values, $account->{data}->{$_};
        }
        return unless @$names;
        return $self->post (['group', 'member', 'data'], {
          context_key => $opts->{context_key},
          group_id => $group_id,
          account_id => $account->{account_id},
          name => $names,
          value => $values,
        })->then (sub {
          my $result = $_[0];
          die $result unless $result->{status} == 200;
        });
      });
    } $members;
  });
} # create_group

sub create_invitation ($$$) {
  my ($self, $name, $opts) = @_;
  return $self->post (['invite', 'create'], {
    context_key => $opts->{context_key} // rand,
    invitation_context_key => $opts->{invitation_context_key} // rand,
    account_id => $opts->{account_id} // int rand 1000000,
    target_account_id => $opts->{target_account_id}, # or undef
    data => (perl2json_chars $opts->{data}), # or undef
  })->then (sub {
    my $result = $_[0];
    die $result unless $result->{status} == 200;
    $self->{objects}->{$name} = $result->{json};
  });
} # create_invitation

sub create_browser ($$$) {
  my ($self, $name, $opts) = @_;
  die "No |browser| option for |Test|"
      if not defined $self->{servers_data}->{wd_actual_url};
  die "Duplicate browser |$name|" if defined $self->{browsers}->{$name};
  $self->{browsers}->{$name} = '';
  require Web::Driver::Client::Connection;
  my $wd = Web::Driver::Client::Connection->new_from_url
      ($self->{servers_data}->{wd_actual_url});
  push @{$self->{wds} ||= []}, $wd;
  return $wd->new_session (
    desired => {},
    http_proxy_url => Web::URL->parse_string ($self->{servers_data}->{docker_envs}->{http_proxy}) || die,
  )->then (sub {
    $self->{browsers}->{$name} = $_[0];
  });
} # create_browser

sub b_go_cs ($$$;%) {
  my ($self, $name, $url, %args) = @_;
  if (ref $url eq 'ARRAY') {
    $url = join '/', map { percent_encode_c $_ } '', @$url;
  }
  $url .= '#' . $args{fragment} if defined $args{fragment};
  $url = Web::URL->parse_string ($url, $self->{servers_data}->{cs_client_url});
  return $self->b ($name)->go ($url);
} # b_go

sub b ($$) {
  my ($self, $name) = @_;
  return $self->{browsers}->{$name} || die "No browser |$name|";
} # b

sub done ($) {
  my $self = $_[0];
  delete $self->{client};
  return Promise->all ([
    (map { $_->close } values %{delete $self->{client_for} or {}}),
    (map { $_->close } values %{delete $self->{browsers} or {}}),
  ])->then (sub {
    return Promise->all ([
      (map { $_->close } @{delete $self->{wds} or []}),
    ]);
  })->finally (sub {
    (delete $self->{context})->done;
  });
} # done

1;

=head1 LICENSE

Copyright 2015-2023 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You does not have received a copy of the GNU Affero General Public
License along with this program, see <https://www.gnu.org/licenses/>.

=cut
