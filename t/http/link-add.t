use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create (
    [a1 => account => {}],
  )->then (sub {
    return $current->are_errors (
      [['link', 'add'], {
        server => 'linktest1',
        sk => $current->o ('a1')->{account}->{sk},
        #sk_context is implied
        linked_key => $current->generate_key (rand, {}),
      }],
      [
        {method => 'GET', status => 405},
        {bearer => undef, status => 401},
        {params => {sk => $current->o ('a1')->{session}->{sk},
                    sk_context => undef,
                    server => 'linktest1',
                    linked_key => rand}, status => 400,
         name => 'no sk_context'},
        {params => {sk => $current->o ('a1')->{session}->{sk},
                    sk_context => rand,
                    server => 'linktest1',
                    linked_key => rand}, status => 400,
         name => 'bad sk_context'},
        {params => {sk => $current->o ('a1')->{session}->{sk},
                    linked_key => rand}, status => 400, name => 'no server'},
        {params => {sk => $current->o ('a1')->{session}->{sk},
                    server => 'hoge',
                    linked_key => rand}, status => 400, name => 'bad server'},
        {params => {sk => $current->o ('a1')->{session}->{sk},
                    server => 'linktest1'}, status => 400,
         name => 'bad linked_key'},
      ],
    );
  })->then (sub {
    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email', 'foo'],
    }, account => 'a1');
  })->then (sub {
    my $result = $_[0];
    test {
      my $acc = $result->{json};
      is 0+keys %{$acc->{links}}, 0;
    } $current->c;
    return $current->post (['link', 'add'], {
      server => 'linktest1',
      sk => $current->o ('a1')->{session}->{sk},
      #sk_context is implied
      linked_key => $current->generate_key ('k1' => {}),
      linked_id => $current->generate_id (i1 => {}),
    });
  })->then (sub {
    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email', 'foo'],
    }, account => 'a1');
  })->then (sub {
    my $result = $_[0];
    test {
      my $acc = $result->{json};
      is 0+keys %{$acc->{links}}, 1;
      my $link = [values %{$acc->{links}}]->[0];
      ok $link->{account_link_id};
      is $link->{service_name}, 'linktest1';
      ok $link->{created};
      ok $link->{updated};
      is $link->{id}, $current->o ('i1');
      is $link->{key}, $current->o ('k1');
      is $link->{name}, undef;
      is $link->{email}, undef;
      is $link->{foo}, undef;
    } $current->c;
    return $current->post (['link', 'add'], {
      server => 'linktest1',
      sk => $current->o ('a1')->{session}->{sk},
      #sk_context is implied
      linked_key => $current->generate_key ('k2' => {}),
    });
  })->then (sub {
    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email', 'foo'],
    }, account => 'a1');
  })->then (sub {
    my $result = $_[0];
    test {
      my $acc = $result->{json};
      is 0+keys %{$acc->{links}}, 2;
      my $links = [sort { $a->{created} <=> $b->{created} } values %{$acc->{links}}];
      my $link = $links->[0];
      ok $link->{account_link_id};
      is $link->{service_name}, 'linktest1';
      ok $link->{created};
      ok $link->{updated};
      is $link->{id}, $current->o ('i1');
      is $link->{key}, $current->o ('k1');
      is $link->{name}, undef;
      is $link->{email}, undef;
      is $link->{foo}, undef;
      my $link2 = $links->[1];
      ok $link2->{account_link_id};
      is $link2->{service_name}, 'linktest1';
      ok $link2->{created};
      ok $link2->{updated};
      is $link2->{id}, undef;
      is $link2->{key}, $current->o ('k2');
      is $link2->{name}, undef;
      is $link2->{email}, undef;
      is $link2->{foo}, undef;
    } $current->c;
    return $current->post (['link', 'add'], {
      server => 'linktest2',
      sk => $current->o ('a1')->{session}->{sk},
      #sk_context is implied
      linked_id => $current->generate_id (i3 => {}),
    });
  })->then (sub {
    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email', 'foo'],
    }, account => 'a1');
  })->then (sub {
    my $result = $_[0];
    test {
      my $acc = $result->{json};
      is 0+keys %{$acc->{links}}, 3;
      my $links = [sort { $a->{created} <=> $b->{created} } values %{$acc->{links}}];
      my $link = $links->[0];
      ok $link->{account_link_id};
      is $link->{service_name}, 'linktest1';
      ok $link->{created};
      ok $link->{updated};
      is $link->{id}, $current->o ('i1');
      is $link->{key}, $current->o ('k1');
      is $link->{name}, undef;
      is $link->{email}, undef;
      is $link->{foo}, undef;
      my $link2 = $links->[1];
      ok $link2->{account_link_id};
      is $link2->{service_name}, 'linktest1';
      ok $link2->{created};
      ok $link2->{updated};
      is $link2->{id}, undef;
      is $link2->{key}, $current->o ('k2');
      is $link2->{name}, undef;
      is $link2->{email}, undef;
      is $link2->{foo}, undef;
      my $link3 = $links->[2];
      ok $link3->{account_link_id};
      is $link3->{service_name}, 'linktest2';
      ok $link3->{created};
      ok $link3->{updated};
      is $link3->{id}, $current->o ('i3');
      is $link3->{key}, undef;
      is $link3->{name}, undef;
      is $link3->{email}, undef;
      is $link3->{foo}, undef;
    } $current->c;
    return $current->post (['link', 'add'], {
      server => 'linktest1',
      account_id => $current->o ('a1')->{account_id},
      linked_key => $current->o ('k2'),
      linked_id => $current->generate_id (i4 => {}),
    });
  })->then (sub {
    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email', 'foo'],
    }, account => 'a1');
  })->then (sub {
    my $result = $_[0];
    test {
      my $acc = $result->{json};
      is 0+keys %{$acc->{links}}, 3;
      my $links = [sort { $a->{created} <=> $b->{created} } values %{$acc->{links}}];
      my $link = $links->[0];
      ok $link->{account_link_id};
      is $link->{service_name}, 'linktest1';
      ok $link->{created};
      ok $link->{updated};
      is $link->{id}, $current->o ('i1');
      is $link->{key}, $current->o ('k1');
      is $link->{name}, undef;
      is $link->{email}, undef;
      is $link->{foo}, undef;
      my $link2 = $links->[2];
      ok $link2->{account_link_id};
      is $link2->{service_name}, 'linktest1';
      ok $link2->{created};
      ok $link2->{updated};
      is $link2->{id}, $current->o ('i4');
      is $link2->{key}, $current->o ('k2');
      is $link2->{name}, undef;
      is $link2->{email}, undef;
      is $link2->{foo}, undef;
      my $link3 = $links->[1];
      ok $link3->{account_link_id};
      is $link3->{service_name}, 'linktest2';
      ok $link3->{created};
      ok $link3->{updated};
      is $link3->{id}, $current->o ('i3');
      is $link3->{key}, undef;
      is $link3->{name}, undef;
      is $link3->{email}, undef;
      is $link3->{foo}, undef;
    } $current->c;
    return $current->post (['link', 'add'], {
      server => 'linktest1',
      account_id => $current->o ('a1')->{account_id},
      linked_id => $current->generate_id (i5 => {}),
      replace => 1,
    });
  })->then (sub {
    return $current->post (['info'], {
      with_linked => ['id', 'key', 'name', 'email', 'foo'],
    }, account => 'a1');
  })->then (sub {
    my $result = $_[0];
    test {
      my $acc = $result->{json};
      is 0+keys %{$acc->{links}}, 2;
      my $links = [sort { $a->{created} <=> $b->{created} } values %{$acc->{links}}];
      my $link = $links->[1];
      ok $link->{account_link_id};
      is $link->{service_name}, 'linktest1';
      ok $link->{created};
      ok $link->{updated};
      is $link->{id}, $current->o ('i5');
      is $link->{key}, undef;
      is $link->{name}, undef;
      is $link->{email}, undef;
      is $link->{foo}, undef;
      my $link3 = $links->[0];
      ok $link3->{account_link_id};
      is $link3->{service_name}, 'linktest2';
      ok $link3->{created};
      ok $link3->{updated};
      is $link3->{id}, $current->o ('i3');
      is $link3->{key}, undef;
      is $link3->{name}, undef;
      is $link3->{email}, undef;
      is $link3->{foo}, undef;
    } $current->c;
  });
} n => 106, name => '/link/add';

RUN;

=head1 LICENSE

Copyright 2021 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
