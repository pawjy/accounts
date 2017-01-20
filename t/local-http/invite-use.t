use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

my $wait = web_server;

Test {
  my $current = shift;
  return $current->create_invitation (i1 => {})->then (sub {
    return $current->are_errors (
      [['invite', 'use'], {
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
          context_key => $current->o ('i1')->{context_key},
          invitation_context_key => $current->o ('i1')->{invitation_context_key},
          invitation_key => $current->o ('i1')->{invitation_key},
          account_id => undef,
        }, status => 400},
        {params => {
          context_key => $current->o ('i1')->{context_key},
          invitation_context_key => $current->o ('i1')->{invitation_context_key},
          invitation_key => $current->o ('i1')->{invitation_key},
          account_id => 0,
        }, status => 400},
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
        }, status => 400, reason => 'Bad |invitation_key|'},
      ],
    );
  })->then (sub {
    return $current->post (['invite', 'use'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      invitation_key => $current->o ('i1')->{invitation_key},
      account_id => 2235353333344444,
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{invitation_data}, undef;
    } $current->c;
    return $current->post (['invite', 'list'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $inv = $result->{json}->{invitations}->{$current->o ('i1')->{invitation_key}};
      is $inv->{invitation_key}, $current->o ('i1')->{invitation_key};
      ok $inv->{author_account_id};
      is $inv->{invitation_data}, undef;
      is $inv->{target_account_id}, 0;
      ok $inv->{created};
      ok $inv->{expires} > $inv->{created};
      is $inv->{user_account_id}, 2235353333344444;
      is $inv->{used_data}, undef;
      ok $inv->{used};
    } $current->c;
  });
} wait => $wait, n => 12, name => '/invite/use';

Test {
  my $current = shift;
  return $current->create_invitation (i1 => {data => ["ab", "\x{6101}"]})->then (sub {
    return $current->post (['invite', 'use'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      invitation_key => $current->o ('i1')->{invitation_key},
      account_id => 2235353333344444,
      data => (perl2json_chars {abc => "\x{5000}"}),
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{invitation_data}->[1], "\x{6101}";
    } $current->c;
    return $current->post (['invite', 'list'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $inv = $result->{json}->{invitations}->{$current->o ('i1')->{invitation_key}};
      is $inv->{invitation_key}, $current->o ('i1')->{invitation_key};
      ok $inv->{author_account_id};
      is $inv->{invitation_data}->[0], "ab";
      is $inv->{target_account_id}, 0;
      ok $inv->{created};
      ok $inv->{expires} > $inv->{created};
      is $inv->{user_account_id}, 2235353333344444;
      is $inv->{used_data}->{abc}, "\x{5000}";
      ok $inv->{used};
    } $current->c;
  });
} wait => $wait, n => 11, name => '/invite/use with data';

Test {
  my $current = shift;
  return $current->create_invitation (i1 => {
    data => ["ab", "\x{6101}"],
    target_account_id => 636444444334,
  })->then (sub {
    return $current->are_errors (
      [['invite', 'use'], {}],
      [
       {params => {
          context_key => $current->o ('i1')->{context_key},
          invitation_context_key => $current->o ('i1')->{invitation_context_key},
          invitation_key => $current->o ('i1')->{invitation_key},
          account_id => 636444444335,
          data => (perl2json_chars {abc => "\x{5000}"}),
        }, status => 400, reason => 'Bad invitation', name => 'Not targetted account'},
      ],
    );
  })->then (sub {
    return $current->post (['invite', 'use'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      invitation_key => $current->o ('i1')->{invitation_key},
      account_id => 636444444334,
      data => (perl2json_chars {abc => "\x{5000}"}),
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{invitation_data}->[1], "\x{6101}";
    } $current->c;
    return $current->post (['invite', 'list'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $inv = $result->{json}->{invitations}->{$current->o ('i1')->{invitation_key}};
      is $inv->{invitation_key}, $current->o ('i1')->{invitation_key};
      ok $inv->{author_account_id};
      is $inv->{invitation_data}->[0], "ab";
      is $inv->{target_account_id}, 636444444334;
      ok $inv->{created};
      ok $inv->{expires} > $inv->{created};
      is $inv->{user_account_id}, 636444444334;
      is $inv->{used_data}->{abc}, "\x{5000}";
      ok $inv->{used};
    } $current->c;
  });
} wait => $wait, n => 12, name => '/invite/use targetted';

Test {
  my $current = shift;
  return $current->create_invitation (i1 => {
    data => ["ab", "\x{6101}"],
    target_account_id => 636444444334,
  })->then (sub {
    return $current->post (['invite', 'use'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
      invitation_key => $current->o ('i1')->{invitation_key},
      account_id => 636444444335,
      ignore_target => 1,
      data => (perl2json_chars {abc => "\x{5000}"}),
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is $result->{status}, 200;
      is $result->{json}->{invitation_data}->[1], "\x{6101}";
    } $current->c;
    return $current->post (['invite', 'list'], {
      context_key => $current->o ('i1')->{context_key},
      invitation_context_key => $current->o ('i1')->{invitation_context_key},
    });
  })->then (sub {
    my $result = $_[0];
    test {
      my $inv = $result->{json}->{invitations}->{$current->o ('i1')->{invitation_key}};
      is $inv->{invitation_key}, $current->o ('i1')->{invitation_key};
      ok $inv->{author_account_id};
      is $inv->{invitation_data}->[0], "ab";
      is $inv->{target_account_id}, 636444444334;
      ok $inv->{created};
      ok $inv->{expires} > $inv->{created};
      is $inv->{user_account_id}, 636444444335;
      is $inv->{used_data}->{abc}, "\x{5000}";
      ok $inv->{used};
    } $current->c;
  });
} wait => $wait, n => 11, name => '/invite/use targetted but ignored';

run_tests;
stop_web_server;

=head1 LICENSE

Copyright 2017 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
