use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

for my $server_type (qw(oauth1server oauth2server)) {

  Test {
    my $current = shift;
    return $current->create_browser (1 => {})->then (sub {
      return $current->b_go_cs (1 => qq</start?copied_data_field=id:abcid&copied_data_field=name:fuga&server=> . $server_type);
    })->then (sub {
      return $current->b (1)->execute (q{
        document.querySelector ('form [type=submit]').click ();
      });
    })->then (sub {
      return $current->b (1)->url;
    })->then (sub {
      my $url = $_[0];
      test {
        like $url->stringify, qr{^http://[^/]+/cb\?}; # client_url(cs)
      } $current->c;
    })->then (sub {
      return $current->b_go_cs (1 => q</info?with_data=abcid&with_data=fuga>);
    })->then (sub {
      return $current->b (1)->execute (q{
        return document.body.textContent;
      });
    })->then (sub {
      my $json = json_bytes2perl $_[0]->json->{value};
      test {
        is $json->{data}->{abcid}, undef;
        is $json->{data}->{fuga}, undef;
      } $current->c, name => '/info';
    });
  } n => 3, name => ['/oauth copied_data_field', $server_type], browser => 1;
}

RUN;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
