use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return Promise->resolve->then (sub {
    return $current->post (['profiles'], {
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is 0+keys %{$res->{json}->{accounts}}, 0;
    } $current->c;
  });
} n => 1, name => '/profiles without account_id';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->are_errors (
      [['profiles'], {
        account_id => $current->o ('a1')->{account_id},
      }],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {bearer => rand, status => 401},
      ],
    );
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
    });
  })->then (sub {
    my $res = $_[0];
    test {
      my $data = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
      is $data->{account_id}, $current->o ('a1')->{account_id};
      is $data->{name}, $current->o ('n1');
      like $res->{res}->body_bytes, qr{"account_id"\s*:\s*"};
    } $current->c;
  });
} n => 4, name => '/profiles with account_id, matched';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->create_account (a2 => {
      name => $current->generate_text ('n2'),
    });
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => [$current->o ('a1')->{account_id},
                     $current->o ('a2')->{account_id},
                     $current->generate_id ('id1')],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      my $data = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
      is $data->{account_id}, $current->o ('a1')->{account_id};
      is $data->{name}, $current->o ('n1');
      my $data2 = $res->{json}->{accounts}->{$current->o ('a2')->{account_id}};
      is $data2->{account_id}, $current->o ('a2')->{account_id};
      is $data2->{name}, $current->o ('n2');
      ok ! $res->{json}->{accounts}->{$current->o ('id1')};
      like $res->{res}->body_bytes, qr{"account_id"\s*:\s*"};
      is $data2->{user_status}, undef;
      is $data2->{admin_status}, undef;
      is $data2->{terms_version}, undef;
    } $current->c;
    return $current->post (['profiles'], {
      account_id => [$current->o ('a1')->{account_id},
                     rand],
    });
  })->then (sub {
    my $result = $_[0];
    test {
      is 0+keys %{$result->{json}->{accounts}}, 1;
    } $current->c;
  });
} n => 10, name => '/profiles with account_id, multiple';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
      user_status => [2, 3],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{json}->{accounts}->{$current->o ('a1')->{account_id}}, undef;
    } $current->c;
  });
} n => 1, name => '/profiles with account_id, user_status filtered';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
      admin_status => [2, 3],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{json}->{accounts}->{$current->o ('a1')->{account_id}}, undef;
    } $current->c;
  });
} n => 1, name => '/profiles with account_id, admin_status filtered';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->post (['account', 'user_status'], {
      user_status => 2,
    }, account => 'a1');
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
      user_status => [1, 3],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{json}->{accounts}->{$current->o ('a1')->{account_id}}, undef;
    } $current->c;
  });
} n => 1, name => '/profiles with account_id, user_status filtered 2';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->post (['account', 'admin_status'], {
      admin_status => 2,
    }, account => 'a1');
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
      admin_status => [1, 3],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      is $res->{json}->{accounts}->{$current->o ('a1')->{account_id}}, undef;
    } $current->c;
  });
} n => 1, name => '/profiles with account_id, admin_status filtered 2';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->post (['account', 'user_status'], {
      user_status => 3,
    }, account => 'a1');
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
      user_status => [1, 3],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      ok $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
    } $current->c;
  });
} n => 1, name => '/profiles with account_id, user_status filtered 3';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->post (['account', 'admin_status'], {
      admin_status => 1,
    }, account => 'a1');
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
      admin_status => [1, 3],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      ok $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
    } $current->c;
  });
} n => 1, name => '/profiles with account_id, admin_status filtered 3';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
      with_icon => [$current->generate_context_key ('ctx1' => {})],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      my $data = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
      is 0+keys %{$data->{icons}}, 0;
      is $data->{icons}->{$current->o ('ctx1')}, undef;
    } $current->c;
  });
} n => 2, name => '/profiles with_icons no icon';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->post (['icon', 'updateform'], {
      context_key => $current->generate_context_key ('ctx1' => {}),
      target_type => 1,
      target_id => $current->o ('a1')->{account_id},
      mime_type => 'image/jpeg',
      byte_length => length ($current->generate_bytes (b1 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    $current->set_o (icon_url => $res->{json}->{icon_url});
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
      with_icon => [$current->o ('ctx1')],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      my $data = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
      is 0+keys %{$data->{icons}}, 1;
      is $data->{icons}->{$current->o ('ctx1')}, $current->o ('icon_url');
    } $current->c;
  });
} n => 2, name => '/profiles with_icon';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
    name => $current->generate_text ('n1'),
  })->then (sub {
    return $current->post (['icon', 'updateform'], {
      context_key => $current->generate_context_key ('ctx1' => {}),
      target_type => 1,
      target_id => $current->o ('a1')->{account_id},
      mime_type => 'image/jpeg',
      byte_length => length ($current->generate_bytes (b1 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    $current->set_o (icon_url => $res->{json}->{icon_url});
    return $current->post (['icon', 'updateform'], {
      context_key => $current->generate_context_key ('ctx2' => {}),
      target_type => 1,
      target_id => $current->o ('a1')->{account_id},
      mime_type => 'image/jpeg',
      byte_length => length ($current->generate_bytes (b1 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    $current->set_o (icon_url2 => $res->{json}->{icon_url});
    return $current->post (['profiles'], {
      account_id => $current->o ('a1')->{account_id},
      with_icon => [$current->o ('ctx1'), $current->o ('ctx2')],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      my $data = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
      is 0+keys %{$data->{icons}}, 2;
      is $data->{icons}->{$current->o ('ctx1')}, $current->o ('icon_url');
      is $data->{icons}->{$current->o ('ctx2')}, $current->o ('icon_url2');
    } $current->c;
  });
} n => 3, name => '/profiles with_icon 2';

Test {
  my $current = shift;
  return $current->create_account (a1 => {
  })->then (sub {
    return $current->create_account (a2 => {});
  })->then (sub {
    return $current->post (['icon', 'updateform'], {
      context_key => $current->generate_context_key ('ctx1' => {}),
      target_type => 1,
      target_id => $current->o ('a1')->{account_id},
      mime_type => 'image/jpeg',
      byte_length => length ($current->generate_bytes (b1 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    $current->set_o (icon_url => $res->{json}->{icon_url});
    return $current->post (['icon', 'updateform'], {
      context_key => $current->generate_context_key ('ctx2' => {}),
      target_type => 1,
      target_id => $current->o ('a1')->{account_id},
      mime_type => 'image/jpeg',
      byte_length => length ($current->generate_bytes (b1 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    $current->set_o (icon_url2 => $res->{json}->{icon_url});
    return $current->post (['icon', 'updateform'], {
      context_key => $current->o ('ctx2' => {}),
      target_type => 1,
      target_id => $current->o ('a2')->{account_id},
      mime_type => 'image/jpeg',
      byte_length => length ($current->generate_bytes (b1 => {})),
    });
  })->then (sub {
    my $res = $_[0];
    $current->set_o (icon_url3 => $res->{json}->{icon_url});
    return $current->post (['profiles'], {
      account_id => [$current->o ('a1')->{account_id},
                     $current->o ('a2')->{account_id}],
      with_icon => [$current->o ('ctx1'), $current->o ('ctx2')],
    });
  })->then (sub {
    my $res = $_[0];
    test {
      my $data = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
      is 0+keys %{$data->{icons}}, 2;
      is $data->{icons}->{$current->o ('ctx1')}, $current->o ('icon_url');
      is $data->{icons}->{$current->o ('ctx2')}, $current->o ('icon_url2');
      my $data2 = $res->{json}->{accounts}->{$current->o ('a2')->{account_id}};
      is 0+keys %{$data2->{icons}}, 1;
      is $data2->{icons}->{$current->o ('ctx1')}, undef;
      is $data2->{icons}->{$current->o ('ctx2')}, $current->o ('icon_url3');
    } $current->c;
  });
} n => 6, name => '/profiles with_icon 3';

Test {
  my $current = shift;
  return $current->create (
    [a1 => account => {
    }],
  )->then (sub {
    return $current->post (['profiles'], {
      account_id => [
        $current->o ('a1')->{account_id},
      ],
      with_statuses => 1,
    });
  })->then (sub {
    my $res = $_[0];
    test {
      {
        my $acc = $res->{json}->{accounts}->{$current->o ('a1')->{account_id}};
        is $acc->{user_status}, 1;
        is $acc->{admin_status}, 1;
        is $acc->{terms_version}, 0;
      }
    } $current->c;
  });
} n => 3, name => 'statuses';

RUN;

=head1 LICENSE

Copyright 2015-2024 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
