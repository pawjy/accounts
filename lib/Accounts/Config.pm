package Accounts::Config;
use strict;
use warnings;
use Encode;
use Path::Tiny;
use Promised::File;
use MIME::Base64;
use JSON::PS;
use Dongry::Database;

sub from_file_name ($$) {
  my ($class, $file_name) = @_;
  my $file = Promised::File->new_from_path ($file_name);
  return $file->read_byte_string->then (sub {
    my $json = json_bytes2perl $_[0];
    for my $key (keys %$json) {
      my $value = $json->{$key};
      if (defined $value and ref $value eq 'ARRAY') {
        if (not defined $value->[0]) {
          #
        } elsif ($value->[0] eq 'Base64') {
          $json->{$key} = decode_base64 $value->[1] // '';
        }
      }
    }
    die "$file_name: Not a JSON object" unless defined $json;

    my $servers_file_name = $json->{servers_json_file}
        // die "|servers_json_file| option is not specified";
    my $servers_file = path ($servers_file_name)->absolute (path ($file_name)->parent);
    my $servers = json_bytes2perl $servers_file->slurp;

    return bless {json => $json, servers => $servers}, $class;
  });
} # from_file_name

sub get ($$) {
  return $_[0]->{json}->{$_[1]};
} # get

sub get_oauth_server ($$) {
  my ($self, $server_name) = @_;
  return $self->{servers}->{$server_name // ''}; # or undef
} # get_oauth_server

$Dongry::Types->{json} = {
  parse => sub {
    if (defined $_[0]) {
      return json_bytes2perl $_[0];
    } else {
      return undef;
    }
  },
  serialize => sub {
    if (defined $_[0]) {
      return perl2json_bytes $_[0];
    } else {
      return undef;
    }
  },
}; # json

my $Schema = {
  session => {
    type => {data => 'json'},
    primary_keys => ['sk'],
  },
  account => {
    type => {name => 'text'},
    primary_keys => ['account_id'],
  },
  account_link => {
    type => {linked_id => 'text', linked_key => 'text', linked_name => 'text'},
    primary_keys => ['account_link_id'],
  },
}; # $Schema

sub get_db ($) {
  my $config = $_[0]->{json};
  my $sources = {};
  $sources->{master} = {
    dsn => (encode 'utf-8', $config->{alt_dsns}->{master}->{account}),
    writable => 1, anyevent => 1,
  };
  return Dongry::Database->new (sources => $sources, schema => $Schema);
} # get_db

1;
