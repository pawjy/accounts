package Tests::Current;
use strict;
use warnings;
use JSON::PS;
use Web::URL;
use Web::Transport::ConnectionClient;
use Promised::Flow;
use Test::More;
use Test::X1;

sub c ($) {
  return $_[0]->{context};
} # c

sub client ($) {
  my $self = $_[0];
  return $self->{client} ||= do {
    my $host = $self->{context}->received_data->{host};
    my $url = Web::URL->parse_string ("http://$host");
    my $http = Web::Transport::ConnectionClient->new_from_url ($url);
    $http;
  };
} # client

#XXX
sub object ($$$) {
  my ($self, $type, $name) = @_;
  return $self->{objects}->{$name} || die "Object ($type, $name) not found";
} # object

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

sub generate_id ($$$) {
  my ($self, $name, $opts) = @_;
  return $self->{objects}->{$name} = int rand 100000000;
} # generate_id

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

sub post ($$$;%) {
  my ($self, $path, $params, %args) = @_;
  my $p = {sk_context => 'tests'};
  if (defined $args{session}) {
    my $session = $self->object ('session', $args{session});
    $p->{sk} = $session->{sk};
  }
  return $self->client->request (
    method => 'POST',
    (ref $path ?
      (path => $path)
    :
      (url => Web::URL->parse_string ($path, Web::URL->parse_string ($self->client->origin->to_ascii)))
    ),
    bearer => $self->c->received_data->{keys}->{'auth.bearer'},
    params => {%$p, %$params},
  )->then (sub {
    my $res = $_[0];
    if ($res->status == 200 or $res->status == 400) {
      return {res => $res,
              status => $res->status,
              json => json_bytes2perl $res->body_bytes};
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
      params => $base_params,
      bearer => $self->c->received_data->{keys}->{'auth.bearer'},
      %base_args,
      %$test,
    );
    return $self->client->request (
      method => $opt{method}, path => $opt{path}, params => $opt{params},
      bearer => $opt{bearer},
    )->then (sub {
      my $res = $_[0];
      unless ($opt{status} == $res->status) {
        test {
          is $res->status, $opt{status}, $res;
        } $self->c, name => $opt{name};
        $has_error = 1;
      }
      if (defined $opt{reason}) {
        my $json = json_bytes2perl $res->body_bytes;
        unless (defined $json and
                ref $json eq 'JSON' and
                defined $json->{reason} and
                $json->{reason} eq $opt{reason}) {
          test {
            is $json->{reason}, $opt{reason};
          } $self->c, name => $opt{name};
          $has_error = 1;
        }
      }
    });
  } $tests)->then (sub {
    unless ($has_error) {
      test {
        ok 1, 'no error';
      } $self->c;
    }
  });
} # are_errors

sub create_session ($$$) {
  my ($self, $name, $opts) = @_;
  return $self->post (['session'], {})->then (sub {
    die $_[0]->{res} unless $_[0]->{status} == 200;
    $self->{objects}->{$name} = $_[0]->{json};
  });
} # create_session

sub create_account ($$$) {
  my ($self, $name, $opts) = @_;
  my $session;
  return $self->post (['session'], {})->then (sub {
    my $result = $_[0];
    die $result->{res} unless $result->{status} == 200;
    $session = $result->{json};
    return $self->post (['create'], {
      sk => $session->{sk},
      name => $opts->{name},
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
      if (ref $_) {
        $_;
      } else {
        +{account_id => $self->o ($_)->{account_id},
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

sub done ($) {
  my $self = $_[0];
  (delete $self->{context})->done;
  return Promise->all ([
    (defined $self->{client} ? $self->{client}->close : undef),
  ]);
} # done

1;

=head1 LICENSE

Copyright 2015-2018 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You does not have received a copy of the GNU Affero General Public
License along with this program, see <http://www.gnu.org/licenses/>.

=cut
