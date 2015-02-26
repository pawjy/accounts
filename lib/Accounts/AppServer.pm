package Accounts::AppServer;
use strict;
use warnings;
use Warabe::App;
push our @ISA, qw(Warabe::App);
use Path::Tiny;

sub new_from_http_and_config ($$$) {
  my $self = $_[0]->SUPER::new_from_http ($_[1]);
  $self->{config} = $_[2];
  return $self;
} # new_from_http_and_config

sub config ($) {
  return $_[0]->{config};
} # config

sub error_log ($$) {
  #$_[0]->ikachan (1, $_[1]);
  warn "ERROR: $_[1]\n"; # XXX blocking I/O
} # error_log

sub send_json ($$) {
  my ($self, $data) = @_;
  $self->http->set_response_header ('Content-Type' => 'application/json; charset=utf-8');
  $self->http->send_response_body_as_ref (\perl2json_bytes $data);
  $self->http->close_response_body;
} # send_json

my $RootPath = path (__FILE__)->parent->parent->parent;

sub send_file ($$$) {
  my ($self, $file_name, $content_type) = @_;
  ## $file_name MUST be safe.
  $self->http->set_response_header ('Content-Type' => $content_type);
  my $path = $RootPath->child ($file_name);
  unless ($path->is_file) {
    return $self->send_error (404, reason_phrase => 'File not found');
  }
  $self->http->set_response_last_modified ($path->stat->mtime);
  my ($ok, $ng) = @_;
  my $p = Promise->new (sub { ($ok, $ng) = @_ });
  my $hdl; $hdl = AnyEvent::Handle->new
    (fh => $path->openr,
     on_error => sub {
       $self->error_log ("$path: $_[2]");
       $hdl->destroy;
       $ng->();
     },
     on_read => sub {
       $self->http->send_response_body_as_ref (\($_[0]->{rbuf}));
       $hdl->rbuf = '';
     },
     on_eof => sub {
       $hdl->destroy;
       $ok->();
     });
  return $p->catch (sub {
    eval { $self->http->set_status (500, reason_phrase => 'File error') };
  })->then (sub {
    $self->http->close_response_body;
  });
} # send_file

my $TemplatesPath = $RootPath->child ('templates');

use Path::Class; # XXX
sub temma ($$$) {
  my ($self, $template_path, $args) = @_;
  $template_path = $TemplatesPath->child ($template_path);
  die "|$template_path| not found" unless $template_path->is_file;

  my $http = $self->http;
  $http->set_response_header ('Content-Type' => 'text/html; charset=utf-8');
  my $fh = Accounts::AppServer::TemmaPrinter->new_from_http ($http);
  my $ok;
  my $p = Promise->new (sub { $ok = $_[0] });

  my $doc = new Web::DOM::Document;
  my $parser = Temma::Parser->new;
  $parser->parse_f (file ($template_path) => $doc); # XXX blocking
  my $processor = Temma::Processor->new;
  $processor->process_document ($doc => $fh, ondone => sub {
    $http->close_response_body;
    $ok->();
  }, args => $args);

  return $p;
} # temma

package Accounts::AppServer::TemmaPrinter;

sub new_from_http ($$) {
  return bless {http => $_[1]}, $_[0];
} # new_from_http

sub print ($$) {
  $_[0]->{value} .= $_[1];
  if (length $_[0]->{value} > 1024*10 or length $_[1] == 0) {
    $_[0]->{http}->send_response_body_as_text ($_[0]->{value});
    $_[0]->{value} = '';
  }
} # print

sub DESTROY {
  $_[0]->{http}->send_response_body_as_text ($_[0]->{value})
      if length $_[0]->{value};
} # DESTROY

1;

=head1 LICENSE

Copyright 2007-2014 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
