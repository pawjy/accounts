use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

for my $server_type (qw(oauth1server oauth2server)) {

  Test {
    my $current = shift;
    return $current->create_browser (1 => {})->then (sub {
      return $current->b_go_cs (1 => qq</start?app_data=ho%E3%81%82%00e&server=> . $server_type);
    })->then (sub {
      return $current->b (1)->execute (q{
        setTimeout (() => {
          document.querySelector ('form [type=submit]').click ();
        }, 0);
      });
    })->then (sub {
      return $current->b (1)->url;
    })->then (sub {
      my $url = $_[0];
      test {
        like $url->stringify, qr{^http://[^/]+/cb\?}; # client_url ("cs")/cb
      } $current->c;
      return $current->b (1)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $value = $_[0]->json->{value};
      test {
        my $json = json_bytes2perl decode_base64 $value;
        is $json->{status}, 200, 'oauth login result';
        is $json->{app_data}, "ho\x{3042}\x00e";
      } $current->c;
    })->then (sub {
      return $current->b_go_cs (1, q</token?server=> . $server_type);
    })->then (sub {
      return $current->b (1)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->json->{value};
      test {
        if ($server_type =~ /oauth1/) {
          is ref $json->{access_token}, 'ARRAY';
          like $json->{access_token}->[0], qr{.+};
          like $json->{access_token}->[1], qr{.+};
        } else {
          is ref $json->{access_token}, '';
          like $json->{access_token}, qr{.+};
          ok 1;
        }
      } $current->c, name => '/token';
      return $json->{account_id};
    })->then (sub {
      return $current->b_go_cs (1 => q</info>);
    })->then (sub {
      return $current->b (1)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->json->{value};
      test {
        is $json->{name}, $current->{servers_data}->{xs_account_name};
        ok $json->{account_id};
        $current->set_o (aid => $json->{account_id});
        $current->set_o (xid => [values %{$json->{links}}]->[0]->{id});
      } $current->c;
      return $current->b_go_cs (1 => q</profiles?account_id=> . $current->o ('aid'));
    })->then (sub {
      return $current->b (1)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->json->{value};
      test {
        my $aid = $current->o ('aid');
        ok $json->{accounts}->{$aid};
        is $json->{accounts}->{$aid}->{name}, $current->{servers_data}->{xs_account_name};
        is $json->{accounts}->{$aid}->{account_id}, $aid;
      } $current->c, name => '/profiles';
    })->then (sub {
      return $current-> b (1)->close;
    })->then (sub {
      return $current->create_browser (2 => {});
    })->then (sub {
      return $current->b_go_cs (2 => qq</start?server=> . $server_type);
    })->then (sub {
      return $current->b (2)->execute (q{
        setTimeout (() => {
          document.querySelector ('form [type=submit]').click ();
        }, 0);
      });
    })->then (sub {
      return $current->b_go_cs (2 => qq</info>);
    })->then (sub {
      return $current->b (2)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->json->{value};
      test {
        is $json->{name}, $current->{servers_data}->{xs_account_name};
        isnt $json->{account_id}, $current->o ('aid');
      } $current->c, name => 'second login with different ID';
      return $current->b (2)->close;
    })->then (sub {
      return $current->create_browser (3 => {});
    })->then (sub {
      return $current->b_go_cs (3 => qq</start?server=> . $server_type);
    })->then (sub {
      return $current->b (3)->execute (q{
        var input = document.createElement ('input');
        input.type = 'hidden';
        input.name = 'account_id';
        input.value = arguments[0];
        document.querySelector ('form').appendChild (input);
        setTimeout (() => {
          document.querySelector ('form [type=submit]').click ();
        }, 0);
      }, [$current->o ('xid')]);
    })->then (sub {
      return $current->b_go_cs (3 => qq</info>);
    })->then (sub {
      return $current->b (3)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->json->{value};
      test {
        is $json->{name}, $current->{servers_data}->{xs_account_name};
        is $json->{account_id}, $current->o ('aid');
      } $current->c, name => 'second login with same ID';
    });
  } n => 15, name => ['/oauth', $server_type], browser => 1;

  Test {
    my $current = shift;
    return $current->create_browser (1 => {})->then (sub {
      return $current->b_go_cs (1 => qq</start?app_data=ho%E3%81%82%00e&sk_context=sk2&server=> . $server_type);
    })->then (sub {
      return $current->b (1)->execute (q{
        setTimeout (() => {
          document.querySelector ('form [type=submit]').click ();
        }, 0);
      });
    })->then (sub {
      return $current->b (1)->url;
    })->then (sub {
      my $url = $_[0];
      test {
        like $url->stringify, qr{^http://[^/]+/cb\?}; # client_url("cs")/cb
      } $current->c;
    })->then (sub {
      return $current->b (1)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $value = $_[0]->json->{value};
      test {
        my $json = json_bytes2perl decode_base64 $value;
        is $json->{status}, 200, 'oauth login result';
        is $json->{app_data}, "ho\x{3042}\x00e";
      } $current->c;
    })->then (sub {
      return $current->b_go_cs (1 => q</token?sk_context=sk2&server=> . $server_type);
    })->then (sub {
      return $current->b (1)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->json->{value};
      test {
        if ($server_type =~ /oauth1/) {
          is ref $json->{access_token}, 'ARRAY';
          like $json->{access_token}->[0], qr{.+};
          like $json->{access_token}->[1], qr{.+\.SK2\z};
        } else {
          is ref $json->{access_token}, '';
          like $json->{access_token}, qr{.+\.SK2\z};
          ok 1;
        }
      } $current->c, name => '/token';
      return $current->b_go_cs (1 => q</info?sk_context=sk2>);
    })->then (sub {
      return $current->b (1)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->json->{value};
      test {
        is $json->{name}, $current->{servers_data}->{xs_account_name};
        ok $json->{account_id};
      } $current->c;
    });
  } n => 8, name => ['/oauth', $server_type, 'another oauth application'], browser => 1;

  Test {
    my $current = shift;
    return $current->create_browser (1 => {})->then (sub {
      return $current->b_go_cs (1 => q</start?bad_state=1&server=> . $server_type);
    })->then (sub {
      return $current->b (1)->execute (q{
        setTimeout (() => {
          document.querySelector ('form [type=submit]').click ();
        }, 0);
      });
    })->then (sub {
      return $current->b (1)->url;
    })->then (sub {
      my $url = $_[0];
      test {
        like $url->stringify, qr{^http://[^/]+/cb\?}; # client_url("cs")/cb
      } $current->c;
    })->then (sub {
      return $current->b (1)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $value = $_[0]->json->{value};
      test {
        is $value, 400;
      } $current->c;
    });
  } n => 2, name => ['/oauth bad state', $server_type], browser => 1;

  Test {
    my $current = shift;
    return $current->create_browser (1 => {})->then (sub {
      return $current->b_go_cs (1 => qq</start?bad_code=1&server=> . $server_type);
    })->then (sub {
      return $current->b (1)->execute (q{
        setTimeout (() => {
          document.querySelector ('form [type=submit]').click ();
        }, 0);
      });
    })->then (sub {
      return $current->b (1)->url;
    })->then (sub {
      my $url = $_[0];
      test {
        like $url->stringify, qr{^http://[^/]+/cb\?}; # client_url("cs")/cb
      } $current->c;
    })->then (sub {
      return $current->b (1)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $value = $_[0]->json->{value};
      test {
        is $value, 400;
      } $current->c;
    });
  } n => 2, name => ['/oauth bad code', $server_type], browser => 1;
}

RUN;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
