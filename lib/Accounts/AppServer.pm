package Accounts::AppServer;
use strict;
use warnings;
use Warabe::App;
push our @ISA, qw(Warabe::App);
use JSON::PS;
use Promise;
use Web::URL;
use Web::Transport::BasicClient;
use Dongry::Database;

sub new_from_http_and_config ($$$) {
  my $self = $_[0]->SUPER::new_from_http ($_[1]);
  $self->{config} = $_[2];
  return $self;
} # new_from_http_and_config

sub config ($) {
  return $_[0]->{config};
} # config

sub db ($) {
  my $ss = $_[0]->http->server_state;

  # XXX Test::Accounts legacy compat
  return $_[0]->{_dbs}->{main} ||= Dongry::Database->new (%{$_[0]->config->get_db_options})
      unless defined $ss;

  return $ss->data->{dbs}->{main} ||= Dongry::Database->new (%{$_[0]->config->get_db_options});
} # db


my $ThisHost = `hostname`;
chomp $ThisHost;

my $AppName = __PACKAGE__;
$AppName =~ s{::AppServer$}{};

sub ikachan ($$$) {
  my ($self, $is_privmsg, $msg) = @_;
  my $config = $self->config;
  my $prefix = $config->get ('ikachan.url_prefix');
  return unless defined $prefix;
  my $url = Web::URL->parse_string ($prefix . '/' . ($is_privmsg ? 'privmsg' : 'notice'));
  my $client = Web::Transport::BasicClient->new_from_url ($url);
  $client->request (
    url => $url,
    params => {
      channel => $config->get ('ikachan.channel'),
      message => sprintf "%s[%s] %s", $AppName, $ThisHost, $msg,
    },
  )->finally (sub {
    return $client->close;
  });
  return undef;
} # ikachan

sub error_log ($$) {
  $_[0]->ikachan (1, $_[1]);
  warn "ERROR: $_[1]\n";
} # error_log

sub requires_api_key ($) {
  my $self = $_[0];
  my $http = $self->http;
  my $auth = $http->request_auth;
  unless (defined $auth->{auth_scheme} and
          $auth->{auth_scheme} eq 'bearer' and
          length $auth->{token} and
          $auth->{token} eq $self->config->get ('auth.bearer')) {
    $http->set_status (401);
    $http->set_response_auth ('Bearer');
    $http->set_response_header
        ('Content-Type' => 'text/plain; charset=us-ascii');
    $http->send_response_body_as_ref (\'401 Authorization required');
    $http->close_response_body;
    return $self->throw;
  }
} # requires_api_key

sub send_json ($$;%) {
  my ($self, $data, %args) = @_;
  $self->http->set_response_header ('Content-Type' => 'application/json; charset=utf-8');
  my $st = $self->http->response_timing ("json");
  my $body = perl2json_bytes $data;
  $st->add;
  $args{server_timing}->add if defined $args{server_timing};
  $self->http->send_response_body_as_ref (\$body);
  $self->http->close_response_body;
} # send_json

sub send_error_json ($$) {
  my ($self, $data) = @_;
  $self->http->set_status (400);
  $self->http->set_response_header ('Content-Type' => 'application/json; charset=utf-8');
  $self->http->send_response_body_as_ref (\perl2json_bytes $data);
  $self->http->close_response_body;
} # send_error_json

sub throw_error_json ($$) {
  $_[0]->send_error_json ($_[1]);
  $_[0]->throw;
} # throw_error_json

sub shutdown ($) {
  return Promise->resolve;
} # shutdown

1;

=head1 LICENSE

Copyright 2007-2019 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public
License along with this program.  If not, see
<https://www.gnu.org/licenses/>.

=cut
