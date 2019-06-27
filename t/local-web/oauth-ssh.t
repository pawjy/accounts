use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->parent->child ('t_deps/lib');
use Tests;

Test {
  my $current = shift;
  return $current->create_browser (1 => {})->then (sub {
    return $current->b_go_cs (1 => qq</start?app_data=ho%E3%81%82%00e&server=ssh>);
  })->then (sub {
    return $current->b (1)->execute (q{
      return document.body.textContent;
    });
  })->then (sub {
    my $value = $_[0]->json->{value};
    my $json = json_chars2perl $value;
    test {
      is $json->{reason}, 'Not a loginable |server|';
    } $current->c;
    return $current->b (1)->url;
  })->then (sub {
    my $url = $_[0];
    test {
      like $url->stringify, qr{^http://[^/]+/start\?}; # client_url("cs")
    } $current->c;
  })->then (sub {
    return $current->b_go_cs (1 => q</token?server=ssh>);
  })->then (sub {
    return $current->b (1)->execute (q{
      return document.body.textContent;
    });
  })->then (sub {
    my $json = json_bytes2perl $_[0]->json->{value};
    test {
      ok not defined $json->{access_token};
    } $current->c, name => '/token';
  })->then (sub {
    return $current->b_go_cs (1 => q</info>);
  })->then (sub {
    return $current->b (1)->execute (q{
      return document.body.textContent;
    });
  })->then (sub {
    my $json = json_bytes2perl $_[0]->json->{value};
    test {
      is $json->{name}, undef;
      is $json->{account_id}, undef;
    } $current->c;
  });
} n => 5, name => ['/oauth', 'ssh'], browser => 1;

Test {
  my $current = shift;
  return $current->create_browser (1 => {})->then (sub {
    return $current->b_go_cs (1 => qq</start?app_data=ho%E3%81%82%00e&server=hogefugaa13r5>);
  })->then (sub {
    return $current->b (1)->execute (q{
      return document.body.textContent;
    });
  })->then (sub {
    my $value = $_[0]->json->{value};
    my $json = json_chars2perl $value;
    test {
      is $json->{reason}, 'Bad |server|';
    } $current->c;
    return $current->b (1)->url;
  })->then (sub {
    my $url = $_[0];
    test {
      like $url->stringify, qr{^http://[^/]+/start\?}; # client_url("cs")
    } $current->c;
  })->then (sub {
    return $current->b_go_cs (1 => q</token?server=hogefugaa13r5>);
  })->then (sub {
    return $current->b (1)->execute (q{
      return document.body.textContent;
    });
  })->then (sub {
    my $json = json_bytes2perl $_[0]->json->{value};
    test {
      ok not defined $json->{access_token};
    } $current->c, name => '/token';
  })->then (sub {
    return $current->b_go_cs (1 => q</info>);
  })->then (sub {
    return $current->b (1)->execute (q{
      return document.body.textContent;
    });
  })->then (sub {
    my $json = json_bytes2perl $_[0]->json->{value};
    test {
      is $json->{name}, undef;
      is $json->{account_id}, undef;
    } $current->c;
  });
} n => 5, name => ['/oauth', 'unknown server'], browser => 1;

RUN;

=head1 LICENSE

Copyright 2015-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
