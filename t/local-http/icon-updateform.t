use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->are_errors (
    [['icon', 'updateform'], {
      context_key => $current->generate_bytes (rand, {}),
      target_type => 2,
      target_id => $current->generate_id (rand, {}),
      mime_type => 'image/jpeg',
      byte_length => (int rand 10000),
    }],
    [
      {method => 'GET', status => 405},
      {bearer => undef, status => 401},
      {bearer => rand, status => 401},
      {params => {
        target_type => 2,
        target_id => $current->generate_id (rand, {}),
        mime_type => 'image/jpeg',
        byte_length => (int rand 10000),
      }, status => 400, name => 'Bad |context_key|'},
      {params => {
        context_key => $current->generate_bytes (rand, {}),
        target_id => $current->generate_id (rand, {}),
        mime_type => 'image/jpeg',
        byte_length => (int rand 10000),
      }, status => 400, name => 'Bad |target_type|'},
      {params => {
        context_key => $current->generate_bytes (rand, {}),
        target_type => 2,
        mime_type => 'image/jpeg',
        byte_length => (int rand 10000),
      }, status => 400, name => 'Bad |target_id|'},
      {params => {
        context_key => $current->generate_bytes (rand, {}),
        target_type => 2,
        target_id => $current->generate_id (rand, {}),
        byte_length => (int rand 10000),
      }, status => 400, name => 'Bad |mime_type|'},
      {params => {
        context_key => $current->generate_bytes (rand, {}),
        target_type => 2,
        target_id => $current->generate_id (rand, {}),
        mime_type => 'image/svg+xml',
        byte_length => (int rand 10000),
      }, status => 400, name => 'Bad |mime_type|'},
      {params => {
        context_key => $current->generate_bytes (rand, {}),
        target_type => 2,
        target_id => $current->generate_id (rand, {}),
        mime_type => 'image/jpeg',
      }, status => 400, name => 'Bad |byte_length|'},
      {params => {
        context_key => $current->generate_bytes (rand, {}),
        target_type => 2,
        target_id => $current->generate_id (rand, {}),
        mime_type => 'image/jpeg',
        byte_length => 1024*1024*1024,
      }, status => 400, name => 'Bad |byte_length|'},
    ],
  )->then (sub {
    return $current->post (['icon', 'updateform'], {
      context_key => $current->generate_context_key ('ctx1' => {}),
      target_type => 2,
      target_id => $current->generate_id ('id1' => {}),
      mime_type => 'image/jpeg',
      byte_length => length ($current->generate_bytes (b1 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{status}, 200;
      ok 0+keys %{$res->{json}->{form_data}};
      like $res->{json}->{form_url}, qr{^https?://[^/]+/.+$};
      like $res->{json}->{icon_url}, qr{^https?://[^/]+/.+\?[0-9.]+$};
    } $current->c;
    $current->set_o (icon_url => $res->{json}->{icon_url});
    my $url = Web::URL->parse_string ($res->{json}->{form_url});
    my $client = Web::Transport::ConnectionClient->new_from_url ($url);
    return promised_cleanup {
      return $client->close;
    } $client->request (url => $url, method => 'POST', params => {
      %{$res->{json}->{form_data}},
    }, files => {
      file => {body_ref => \($current->o ('b1')), mime_filename => rand},
    })->then (sub {
      my $res = $_[0];
      test {
        ok $res->is_success;
      } $current->c;
    });
  })->then (sub {
    my $url = Web::URL->parse_string ($current->o ('icon_url'));
    my $client = Web::Transport::ConnectionClient->new_from_url ($url);
    return promised_cleanup {
      return $client->close;
    } $client->request (url => $url)->then (sub {
      my $res = $_[0];
      test {
        ok $res->is_success;
        is $res->header ('Content-Type'), 'image/jpeg';
        is $res->body_bytes, $current->o ('b1');
      } $current->c;
    });
  });
} n => 9, name => '/icon/updateform';

Test {
  my $current = shift;
  return Promise->resolve->then (sub {
    return $current->post (['icon', 'updateform'], {
      context_key => $current->generate_context_key ('ctx1' => {}),
      target_type => 2,
      target_id => $current->generate_id ('id1' => {}),
      mime_type => 'image/jpeg',
      byte_length => length ($current->generate_bytes (b1 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{status}, 200;
    } $current->c;
    $current->set_o (icon_url => $res->{json}->{icon_url});
    return $current->post (['icon', 'updateform'], {
      context_key => $current->o ('ctx1'),
      target_type => 2,
      target_id => $current->o ('id1'),
      mime_type => 'image/jpeg',
      byte_length => length ($current->generate_bytes (b2 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{status}, 200;
      my $u = $current->o ('icon_url');
      isnt $res->{json}->{icon_url}, $u;
      ok $res->{json}->{icon_url} =~ s{\?[0-9.]+\z}{};
      ok $u =~ s{\?[0-9.]+\z}{};
      is $res->{json}->{icon_url}, $u;
    } $current->c;
  });
} n => 6, name => '/icon/updateform second invocation';

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->post (['icon', 'updateform'], {
      context_key => 'prefixed',
      target_type => 1,
      target_id => $current->o ('a1')->{account_id},
      mime_type => 'image/png',
      byte_length => length ($current->generate_bytes (b1 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{status}, 200;
      like $res->{json}->{icon_url}, qr{^https?://[^/]+/[^/]+/image/key/prefix/[^/?.]+\.png\?[0-9.]+$};
    } $current->c;
    $current->set_o (icon_url => $res->{json}->{icon_url});
    return $current->post (['icon', 'updateform'], {
      context_key => 'prefixed',
      target_type => 1,
      target_id => $current->o ('a1')->{account_id},
      mime_type => 'image/jpeg',
      byte_length => length ($current->generate_bytes (b2 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{status}, 200;
      my $u = $current->o ('icon_url');
      isnt $res->{json}->{icon_url}, $u;
      $current->set_o (icon_url2 => $res->{json}->{icon_url});
      ok $res->{json}->{icon_url} =~ s{\?[0-9.]+\z}{};
      ok $u =~ s{\?[0-9.]+\z}{};
      is $res->{json}->{icon_url}, $u;
    } $current->c;
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
      with_icon => 'prefixed',
    });
  })->then (sub {
    my $res = $_[0];
    test {
      my $data = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
      is 0+keys %{$data->{icons}}, 1;
      is $data->{icons}->{prefixed}, $current->o ('icon_url2');
    } $current->c;
  });
} n => 9, name => '/icon/updateform prefixed second invocation';

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->post (['icon', 'updateform'], {
      context_key => 'prefixed',
      target_type => 1,
      target_id => $current->o ('a1')->{account_id},
      mime_type => 'image/png',
      byte_length => length ($current->generate_bytes (b1 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{status}, 200;
      like $res->{json}->{icon_url}, qr{^https?://[^/]+/[^/]+/image/key/prefix/[^/]+\.png\?[0-9.]+$};
    } $current->c;
  });
} n => 2, name => '.png';

Test {
  my $current = shift;
  return $current->create_account (a1 => {})->then (sub {
    return $current->post (['icon', 'updateform'], {
      context_key => 'prefixed',
      target_type => 1,
      target_id => $current->o ('a1')->{account_id},
      mime_type => 'image/jpeg',
      byte_length => length ($current->generate_bytes (b1 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{status}, 200;
      like $res->{json}->{icon_url}, qr{^https?://[^/]+/[^/]+/image/key/prefix/[^/]+\.jpeg\?[0-9.]+$};
    } $current->c;
  });
} n => 2, name => '.jpeg';

RUN;

=head1 LICENSE

Copyright 2018 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
