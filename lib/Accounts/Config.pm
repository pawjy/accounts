package Accounts::Config;
use strict;
use warnings;
use Encode;
use Promised::File;
use JSON::PS;
use Dongry::Database;

sub from_file_name ($$) {
  my ($class, $file_name) = @_;
  my $file = Promised::File->new_from_path ($file_name);
  return $file->read_byte_string->then (sub {
    my $json = json_bytes2perl $_[0];
    die "$file_name: Not a JSON object" unless defined $json;
    return bless {json => $json}, $class;
  });
} # from_file_name

my $Schema = {
  hoge => {
    type => {},
    primary_keys => ['id'],
  },
}; # $Schema

sub get_db ($) {
  my $config = $_[0]->{json};
  my $sources = {};
  $sources->{master} = {
    dsn => (encode 'utf-8', $config->{alt_dsns}->{master}->{account}),
    writable => 1, anyevent => 1,
  };
  $sources->{default} = {
    dsn => (encode 'utf-8', $config->{dsns}->{account}),
    anyevent => 1,
  };

  return Dongry::Database->new (sources => $sources, schema => $Schema);
} # get_db

1;
