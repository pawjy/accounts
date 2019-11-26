use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

for my $server_type (qw(oauth1server oauth2server)) {

  Test {
    my $current = shift;
    return $current->create_browser (1 => {})->then (sub {
      return $current->b_go_cs (1 => qq</start?create_email_link=0&server=> . $server_type);
    })->then (sub {
      return $current->b (1)->execute (q{
        setTimeout (() => {
          document.querySelector ('form [type=submit]').click ();
        }, 100);
      });
    })->then (sub {
      return promised_wait_until {
        return $current->b (1)->url->then (sub {
          return $_[0]->path =~ m{/cb};
        });
      } timeout => 34;
    })->then (sub {
      return $current->b (1)->url;
    })->then (sub {
      my $url = $_[0];
      test {
        like $url->stringify, qr{^http://[^/]+/cb\?}; # client_url(cs)
      } $current->c;
    })->then (sub {
      return $current->b_go_cs (1 => q</info?with_linked=id&with_linked=email>);
    })->then (sub {
      return $current->b (1)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->json->{value};
      test {
        is 0+keys %{$json->{links}}, 1;
        my $email;
        for (values %{$json->{links}}) {
          $email = $_ if $_->{service_name} eq 'email';
        }
        is $email, undef;
      } $current->c, name => '/info';
    });
  } n => 3, name => ['/oauth create_email_link', $server_type], browser => 1;

}

RUN;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
