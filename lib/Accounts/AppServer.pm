package Accounts::AppServer;
use strict;
use warnings;
use Warabe::App;
push our @ISA, qw(Warabe::App);
use JSON::PS;
use Promise;
use Web::UserAgent::Functions qw(http_post);

sub new_from_http_and_config ($$$) {
  my $self = $_[0]->SUPER::new_from_http ($_[1]);
  $self->{config} = $_[2];
  return $self;
} # new_from_http_and_config

sub config ($) {
  return $_[0]->{config};
} # config

sub db ($) {
  return $_[0]->{db} ||= $_[0]->config->get_db;
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
  http_post
      url => $prefix . '/' . ($is_privmsg ? 'privmsg' : 'notice'),
      params => {
        channel => $config->get ('ikachan.channel'),
        message => sprintf "%s[%s] %s", $AppName, $ThisHost, $msg,
      },
      anyevent => 1;
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

sub send_json ($$) {
  my ($self, $data) = @_;
  $self->http->set_response_header ('Content-Type' => 'application/json; charset=utf-8');
  $self->http->send_response_body_as_ref (\perl2json_bytes $data);
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
  return $_[0]->{db}->disconnect if defined $_[0]->{db};
  return Promise->resolve;
} # shutdown

1;

=head1 LICENSE

Copyright 2007-2016 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
