use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create_invitation (i1 => {})->then (sub {
    return $current->are_errors (
      [['invite', 'open'], {
        context_key => $current->o ('i1')->{context_key},
        invitation_context_key => $current->o ('i1')->{invitation_context_key},
        invitation_key => $current->o ('i1')->{invitation_key},
        account_id => 532511333,
      }],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {bearer => rand, status => 401},
        {params => {}, status => 400},
        {params => {
          context_key => undef,
          invitation_context_key => $current->o ('i1')->{invitation_context_key},
          invitation_key => $current->o ('i1')->{invitation_key},
          account_id => 62362362333,
        }, status => 400},
        {params => {
          context_key => $current->o ('i1')->{context_key},
          invitation_context_key => undef,
          invitation_key => $current->o ('i1')->{invitation_key},
          account_id => 62362362333,
        }, status => 400},
        {params => {
          context_key => $current->o ('i1')->{context_key},
          invitation_context_key => $current->o ('i1')->{invitation_context_key},
          invitation_key => undef,
          account_id => 62362362333,
        }, status => 400, reason => 'Bad invitation'},
      ],
    );
  })->then (sub {
    return $current->post (['invite', 'open'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      invitation_key => $current->o ('i1')->{invitation_key},
      account_id => 2235353333344444,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $inv = $result->{json};
      is $inv->{invitation_key}, $current->o ('i1')->{invitation_key};
      ok $inv->{author_account_id};
      is $inv->{invitation_data}, undef;
      is $inv->{target_account_id}, 0;
      ok $inv->{created};
      ok $inv->{expires} > $inv->{created};
      is $inv->{user_account_id}, undef;
      is $inv->{used_data}, undef;
      ok ! $inv->{used};
    } $current->c;
  });
} n => 11, name => '/invite/open';

Test {
  my $current = shift;
  return $current->create_invitation (i1 => {})->then (sub {
    return $current->post (['invite', 'open'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      invitation_key => $current->o ('i1')->{invitation_key},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      my $inv = $result->{json};
      is $inv->{invitation_key}, $current->o ('i1')->{invitation_key};
      ok $inv->{author_account_id};
      is $inv->{invitation_data}, undef;
      is $inv->{target_account_id}, 0;
      ok $inv->{created};
      ok $inv->{expires} > $inv->{created};
      is $inv->{user_account_id}, undef;
      is $inv->{used_data}, undef;
      ok ! $inv->{used};
    } $current->c;
  });
} n => 10, name => '/invite/open without account_id';

Test {
  my $current = shift;
  return $current->create_invitation (i1 => {
    data => ["ab", "\x{6101}"],
    target_account_id => 636444444334,
  })->then (sub {
    return $current->are_errors (
      [['invite', 'open'], {}],
      [
       {params => {
          context_key => $current->o ('i1')->{context_key},
          invitation_context_key => $current->o ('i1')->{invitation_context_key},
          invitation_key => $current->o ('i1')->{invitation_key},
          account_id => 636444444335,
        }, status => 400, reason => 'Bad invitation', name => 'Not targetted account'},
       {params => {
          context_key => $current->o ('i1')->{context_key},
          invitation_context_key => $current->o ('i1')->{invitation_context_key},
          invitation_key => $current->o ('i1')->{invitation_key},
          account_id => 0,
        }, status => 400, reason => 'Bad invitation', name => 'Not targetted account'},
       {params => {
          context_key => $current->o ('i1')->{context_key},
          invitation_context_key => $current->o ('i1')->{invitation_context_key},
          invitation_key => $current->o ('i1')->{invitation_key},
        }, status => 400, reason => 'Bad invitation', name => 'Not targetted account'},
      ],
    );
  })->then (sub {
    return $current->post (['invite', 'open'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      invitation_key => $current->o ('i1')->{invitation_key},
      account_id => 636444444334,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $inv = $result->{json};
      is $inv->{invitation_key}, $current->o ('i1')->{invitation_key};
      ok $inv->{author_account_id};
      is $inv->{invitation_data}->[0], "ab";
      is $inv->{target_account_id}, 636444444334;
      ok $inv->{created};
      ok $inv->{expires} > $inv->{created};
      is $inv->{user_account_id}, undef;
      is $inv->{used_data}, undef;
      ok ! $inv->{used};
    } $current->c;
  });
} n => 12, name => '/invite/open targetted';

RUN;

=head1 LICENSE

Copyright 2017-2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
