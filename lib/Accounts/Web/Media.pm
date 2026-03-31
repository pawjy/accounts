package Accounts::Web::Media;
use strict;
use warnings;
use Time::HiRes qw(time);
use Dongry::Type;
use Web::URL;
use Web::DateTime::Clock;
use Web::DOM::Document;
use Web::XML::Parser;
use Web::Transport::AWS;
use Web::Transport::OAuth1;
use Web::Transport::ConnectionClient;
use Web::Transport::BasicClient;
push our @ISA, qw(Accounts::Web);

sub Accounts::Web::load_icons ($$$$$) {
  my ($class, $app, $target_type, $id_key, $items) = @_;
  my $context_keys = $app->bare_param_list ('with_icon');
  return $items unless @$context_keys;
  
  my $id_to_json = {};
  my @id = map {
    $id_to_json->{$_->{$id_key}} = $_;
    $_->{icons} ||= {};
    Dongry::Type->serialize ('text', $_->{$id_key});
  } grep { defined $_->{$id_key} } @$items;
  return $items unless @id;

  return $app->db->select ('icon', {
    context_key => {-in => $context_keys},
    target_type => $target_type,
    target_id => {-in => \@id},
    admin_status => 1, # open
  }, source_name => 'master', fields => [
    'context_key', 'target_id', 'url', 'updated',
  ])->then (sub {
    for (@{$_[0]->all}) {
      my $json = $id_to_json->{$_->{target_id}};
      my $cfg = sub {
        my $n = $_[0];
        return $app->config->get ($n . '.' . $_->{context_key}) //
               $app->config->get ($n); # or undef
      }; # $cfg
      $json->{icons}->{$_->{context_key}} = $cfg->('s3_image_url_prefix') . $_->{url} . '?' . $_->{updated}
          if defined $_->{url} and length $_->{url};
    }
    return $items;
  });
} # load_icons

sub icon ($$$) {
  my ($class, $app, $path) = @_;

  if (@$path == 2 and $path->[1] eq 'updateform') {
    ## /icon/updateform - Get form data to update the icon
    ##
    ## Parameters
    ##   context_key   An opaque string identifying the application.
    ##                 Required.  Note that this is irrelevant to
    ##                 group's |context_key|.
    ##   target_type   Type of the target with which the icon is associated.
    ##                   1 - account
    ##                   2 - group
    ##   target_id     The identifier of the target with which the icon is
    ##                 associated, depending on |target_type|.  It must
    ##                 be a valid target identifier.  It's application's
    ##                 responsibility to ensure the value is valid.
    ##   mime_type     The MIME type of the icon to be submitted.  Either
    ##                 |image/jpeg| or |image/png|.
    ##   byte_length   The byte length of the icon to be submitted.
    ##
    ## Returns
    ##   form_data     Object of |name|/|value| pairs of |hidden| form data.
    ##   form_url      The |action| URL of the form.
    ##   form_expires  The expiration time of the form, in Unix time.
    ##   icon_url      The result URL of the submitted icon.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $context_key = $app->bare_param ('context_key')
        // return $app->throw_error (400, reason_phrase => 'Bad |context_key|');
    my $target_type = $app->bare_param ('target_type') || 0;
    return $app->throw_error (400, reason_phrase => 'Bad |target_type|')
        unless $target_type eq '1' or $target_type eq '2';
    my $target_id = $app->bare_param ('target_id')
        // return $app->throw_error (400, reason_phrase => 'Bad |target_id|');
    
    my $mime_type = $app->bare_param ('mime_type') // '';
    return $app->throw_error_json ({reason => 'Bad |mime_type|'})
        unless $mime_type eq 'image/jpeg' or $mime_type eq 'image/png';
    
    my $byte_length = 0+($app->bare_param ('byte_length') || 0);
    return $app->throw_error_json ({reason => 'Bad |byte_length|'})
        unless 0 < $byte_length and $byte_length <= 10*1024*1024;

    my $cfg = sub {
      my $n = $_[0];
      return $app->config->get ($n . '.' . $context_key) //
             $app->config->get ($n); # or undef
    }; # $cfg

    my $time = time;
    return $app->db->select ('icon', {
      context_key => Dongry::Type->serialize ('text', $context_key),
      target_type => $target_type,
      target_id => $target_id,
    }, source_name => 'master', fields => ['url'])->then (sub {
      my $v = $_[0]->first;
      if (defined $v) {
        return $app->db->update ('icon', {
          updated => $time,
        }, where => {
          context_key => $context_key,
          target_type => $target_type,
          target_id => $target_id,
        })->then (sub { return $v->{url} });
      }

      return $app->db->execute ('select uuid_short() as `id`', undef, source_name => 'master')->then (sub {
        my $id = $_[0]->first->{id};
    
        my $key_prefix = $cfg->('s3_key_prefix') // '';
        my $key = "$id";
        $key = "$key_prefix/$key" if length $key_prefix;

        ## Not changed when updated.
        $key .= {
          'image/png' => '.png',
          'image/jpeg' => '.jpeg',
        }->{$mime_type} // '';
        
        return $app->db->insert ('icon', [{
          context_key => $context_key,
          target_type => $target_type,
          target_id => $target_id,
          created => $time,
          updated => $time,
          admin_status => 1, # open
          url => Dongry::Type->serialize ('text', $key),
        }])->then (sub { return $key }); # duplicate is error!
      });
    })->then (sub {
      my $key = $_[0];
      
      #my $image_url = "https://$service-$region.amazonaws.com/$bucket/$key";
      #my $image_url = "https://$bucket/$key";
      my $image_url = $cfg->('s3_image_url_prefix') . $key . '?' . $time;
      my $bucket = $cfg->('s3_bucket');

      my $accesskey = $cfg->('s3_access_key_id');
      my $secret = $cfg->('s3_secret_access_key');
      my $region = $cfg->('s3_region');
      my $token;
      my $expires;
      my $max_age = 60*60;
      
      return Promise->resolve->then (sub {
        my $sts_role_arn = $cfg->('s3_sts_role_arn');
        return unless defined $sts_role_arn;
        my $sts_url = Web::URL->parse_string
            (qq<https://sts.$region.amazonaws.com/>);
        my $sts_client = Web::Transport::ConnectionClient->new_from_url
            ($sts_url);
        $expires = time + $max_age;
        return $sts_client->request (
          url => $sts_url,
          params => {
            Version => '2011-06-15',
            Action => 'AssumeRole',
            ## Maximum length = 64 (sha1_hex length = 40)
            RoleSessionName => 'accounts-icon-' . sha1_hex ($context_key),
            RoleArn => $sts_role_arn,
            Policy => perl2json_chars ({
              "Version" => "2012-10-17",
              "Statement" => [
                {'Sid' => "Stmt1",
                 "Effect" => "Allow",
                 "Action" => ["s3:PutObject", "s3:PutObjectAcl"],
                 "Resource" => "arn:aws:s3:::$bucket/*"},
              ],
            }),
            DurationSeconds => $max_age,
          },
          aws4 => [$accesskey, $secret, $region, 'sts'],
        )->then (sub {
          my $res = $_[0];
          die $res unless $res->status == 200;

          my $doc = new Web::DOM::Document;
          my $parser = new Web::XML::Parser;
          $parser->onerror (sub { });
          $parser->parse_byte_string ('utf-8', $res->body_bytes => $doc);
          $accesskey = $doc->get_elements_by_tag_name
              ('AccessKeyId')->[0]->text_content;
          $secret = $doc->get_elements_by_tag_name
              ('SecretAccessKey')->[0]->text_content;
          $token = $doc->get_elements_by_tag_name
              ('SessionToken')->[0]->text_content;
        });
      })->then (sub {
        my $acl = "public-read";
        #my $redirect_url = ...;
        my $form_data = Web::Transport::AWS->aws4_post_policy
            (clock => Web::DateTime::Clock->realtime_clock,
             max_age => $max_age,
             access_key_id => $accesskey,
             secret_access_key => $secret,
             security_token => $token,
             region => $region,
             service => 's3',
             policy_conditions => [
               {"bucket" => $bucket},
               {"key", $key}, #["starts-with", q{$key}, $prefix],
               {"acl" => $acl},
               #{"success_action_redirect" => $redirect_url},
               {"Content-Type" => $mime_type},
               ["content-length-range", $byte_length, $byte_length],
             ]);
        return $app->send_json ({
          form_data => {
            key => $key,
            acl => $acl,
            #success_action_redirect => $redirect_url,
            "Content-Type" => $mime_type,
            %$form_data,
          },
          form_url => $cfg->('s3_form_url'),
          icon_url => $image_url,
        });
      });
    });
  } # /icon/updateform
  
  return $app->throw_error (404);
} # icon

1;

=head1 LICENSE

Copyright 2007-2026 Wakaba <wakaba@suikawiki.org>.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Affero General Public License for more details.

You does not have received a copy of the GNU Affero General Public
License along with this program, see <https://www.gnu.org/licenses/>.

=cut
