use strict;
use warnings;
use Path::Tiny;
use Web::Transport::Base64;

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

warn "Public and private keys:\n";
{
  local $/ = undef;
  open my $pubkey, '<', $pub_key_path or die $!;
  my $text = <$pubkey>;
  $text =~ s/^-+(?:BEGIN|END) PUBLIC KEY-+$//mg;
  warn $text;
  my $bytes = decode_web_base64 $text;
  my $key = substr $bytes, -32;
  my $text = join ',', map { ord $_ } split //, $key;
  warn "[$text]\n";
}
{
  local $/ = undef;
  open my $prvkey, '<', $prv_key_path or die $!;
  my $text = <$prvkey>;
  $text =~ s/^-+(?:BEGIN|END) PRIVATE KEY-+$//mg;
  my $bytes = decode_web_base64 $text;
  my $key = substr $bytes, -32;
  my $text = join ',', map { ord $_ } split //, $key;
  warn "[$text]\n";
}

## License: Public Domain.
