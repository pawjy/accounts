use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create_invitation (i1 => {
    account_id => 532525265534,
  })->then (sub {
    return $current->are_errors (
      [['invite', 'list'], {
        context_key => $current->o ('i1')->{context_key},
        invitation_context_key => $current->o ('i1')->{invitation_context_key},
      }],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {bearer => rand, status => 401},
      ],
    );
  })->then (sub {
    return $current->post (['invite', 'list'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{invitations}}, 1;
      my $inv = $result->{json}->{invitations}->{$current->o ('i1')->{invitation_key}};
      is $inv->{invitation_key}, $current->o ('i1')->{invitation_key};
      is $inv->{author_account_id}, 532525265534;
      is $inv->{invitation_data}, undef;
      is $inv->{target_account_id}, 0;
      ok $inv->{created};
      ok $inv->{expires} > $inv->{created};
      is $inv->{user_account_id}, 0;
      is $inv->{used_data}, undef;
      is $inv->{used}, 0;
      like $result->{res}->body_bytes, qr{"author_account_id"\s*:\s*"};
      like $result->{res}->body_bytes, qr{"target_account_id"\s*:\s*"};
      like $result->{res}->body_bytes, qr{"user_account_id"\s*:\s*"};
    } $current->c;
  });
} n => 14, name => '/invite/list';

Test {
  my $current = shift;
  return $current->create_invitation (i1 => {
    account_id => 532525265534,
  })->then (sub {
    return $current->create_invitation (i2 => {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      account_id => 5325252131111,
    });
  })->then (sub {
    return $current->post (['invite', 'list'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{invitations}}, 2;
      my $inv = $result->{json}->{invitations}->{$current->o ('i1')->{invitation_key}};
      is $inv->{invitation_key}, $current->o ('i1')->{invitation_key};
      is $inv->{author_account_id}, 532525265534;
      is $inv->{invitation_data}, undef;
      is $inv->{target_account_id}, 0;
      ok $inv->{created};
      ok $inv->{expires} > $inv->{created};
      is $inv->{user_account_id}, 0;
      is $inv->{used_data}, undef;
      is $inv->{used}, 0;
      my $inv2 = $result->{json}->{invitations}->{$current->o ('i2')->{invitation_key}};
      is $inv2->{invitation_key}, $current->o ('i2')->{invitation_key};
      is $inv2->{author_account_id}, 5325252131111;
      is $inv2->{invitation_data}, undef;
      is $inv2->{target_account_id}, 0;
      ok $inv2->{created};
      ok $inv2->{expires} > $inv->{created};
      is $inv2->{user_account_id}, 0;
      is $inv2->{used_data}, undef;
      is $inv2->{used}, 0;
      like $result->{res}->body_bytes, qr{"author_account_id"\s*:\s*"};
      like $result->{res}->body_bytes, qr{"target_account_id"\s*:\s*"};
      like $result->{res}->body_bytes, qr{"user_account_id"\s*:\s*"};
    } $current->c;
  });
} n => 22, name => '/invite/list';

Test {
  my $current = shift;
  return $current->create_invitation (i1 => {
    account_id => 532525265534,
  })->then (sub {
    return $current->create_invitation (i2 => {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      account_id => 5325252131111,
    });
  })->then (sub {
    return $current->create_invitation (i3 => {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      account_id => 532525432111,
    });
  })->then (sub {
    return $current->are_errors (
      [['invite', 'list'], {}],
      [
        {params => {
          context_key => $current->o ('i1')->{context_key},
          invitation_context_key => $current->o ('i1')->{invitation_context_key},
          limit => 2000,
        }, status => 400, reason => 'Bad |limit|'},
        {params => {
          context_key => $current->o ('i1')->{context_key},
          invitation_context_key => $current->o ('i1')->{invitation_context_key},
          ref => 'abcde',
        }, status => 400, reason => 'Bad |ref|'},
        {params => {
          context_key => $current->o ('i1')->{context_key},
          invitation_context_key => $current->o ('i1')->{invitation_context_key},
          ref => '+532233.333,10000',
        }, status => 400, reason => 'Bad |ref| offset'},
      ],
    );
  })->then (sub {
    return $current->post (['invite', 'list'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{invitations}}, 2;
      ok $result->{json}->{invitations}->{$current->o ('i3')->{invitation_key}};
      ok $result->{json}->{invitations}->{$current->o ('i2')->{invitation_key}};
      ok $result->{json}->{next_ref};
      ok $result->{json}->{has_next};
    } $current->c;
    return $current->post (['invite', 'list'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      ref => $result->{json}->{next_ref},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{invitations}}, 1;
      ok $result->{json}->{invitations}->{$current->o ('i1')->{invitation_key}};
      ok $result->{json}->{next_ref};
      ok ! $result->{json}->{has_next};
    } $current->c;
    return $current->post (['invite', 'list'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      ref => $result->{json}->{next_ref},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{invitations}}, 0;
      ok $result->{json}->{next_ref};
      ok ! $result->{json}->{has_next};
    } $current->c;
    return $current->post (['invite', 'list'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      ref => $result->{json}->{next_ref},
      limit => 2,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is 0+keys %{$result->{json}->{invitations}}, 0;
      ok $result->{json}->{next_ref};
      ok ! $result->{json}->{has_next};
    } $current->c;
  });
} n => 22, name => '/invitation/list paging';

RUN;

=head1 LICENSE

Copyright 2017-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
