use strict;
use warnings;
use Path::Tiny;

my $RootPath = path (__FILE__)->parent->parent;

my $openssl = $ENV{OPENSSL} || 'openssl';

my $name = rand;

my $pub_key_path = $RootPath->child ('local/key-' . $name . '-pub.pem');
my $prv_key_path = $RootPath->child ('local/key-' . $name . '-prv.pem');

sub run (@) {
  warn "|@_|";
  system (@_) == 0 or die $?;
}

run $openssl, qw(genpkey -algorithm ed25519 -out), $prv_key_path;
run $openssl, qw(pkey -in), $prv_key_path, qw(-pubout -out), $pub_key_path;

warn "Public key: |$pub_key_path|\n";
warn "Private key: |$prv_key_path|\n";

## License: Public Domain.
