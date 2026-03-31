package Accounts::Web::Groups;
use strict;
use warnings;
use Time::HiRes qw(time);
use Dongry::Type;
push our @ISA, qw(Accounts::Web);

BEGIN { *status_filter = \&Accounts::Web::status_filter }
BEGIN { *id = \&Accounts::Web::id }
BEGIN { *this_page = \&Accounts::Web::this_page }
BEGIN { *next_page = \&Accounts::Web::next_page }

sub group ($$$) {
  my ($class, $app, $path) = @_;

  if (@$path == 2 and $path->[1] eq 'create') {
    ## /group/create - create a group
    ##
    ## With
    ##   context_key    An opaque string identifying the application.  Required.
    ##   owner_status  A 7-bit positive integer of the group's |owner_status|.
    ##                 Default is 1.
    ##   admin_status  A 7-bit positive integer of the group's |admin_status|.
    ##                 Default is 1.
    ##
    ## Returns
    ##   context_key    Same as |context_key|, for convenience.
    ##   group_id      A 64-bit non-negative integer identifying the group.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $context_key = $app->bare_param ('context_key')
        // return $app->throw_error (400, reason_phrase => 'No |context_key|');
    return $app->db->execute ('select uuid_short() as uuid', undef, source_name => 'master')->then (sub {
      my $group_id = $_[0]->first->{uuid};
      my $time = time;
      return $app->db->insert ('group', [{
        context_key => $context_key,
        group_id => $group_id,
        created => $time,
        updated => $time,
        owner_status => $app->bare_param ('owner_status') // 1, # open
        admin_status => $app->bare_param ('admin_status') // 1, # open
      }])->then (sub {
        return $app->send_json ({
          context_key => $context_key,
          group_id => ''.$group_id,
        });
      });
    });
  } # /group/create

  if (@$path == 2 and $path->[1] eq 'data') {
    ## /group/data - Write group data
    ##
    ## With
    ##   context_key    An opaque string identifying the application.  Required.
    ##   group_id    The group ID.  Required.
    ##   name (0+)   The keys of data pairs.  A key is an ASCII string.
    ##   value (0+)  The values of data pairs.  There must be same number
    ##               of |value|s as |name|s.  A value is a Unicode string.
    ##               An empty string is equivalent to missing.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $group_id = $app->bare_param ('group_id')
        or return $app->throw_error (400, reason_phrase => 'Bad |group_id|');
    return $app->db->select ('group', {
      context_key => $app->bare_param ('context_key'),
      group_id => $group_id,
    }, fields => ['group_id'], source_name => 'master')->then (sub {
      my $x = ($_[0]->first or {})->{group_id};
      return $app->throw_error (404, reason_phrase => '|group_id| not found')
          unless $x and $x eq $group_id;

      my $time = time;
      my $names = $app->text_param_list ('name');
      my $values = $app->text_param_list ('value');
      my @data;
      for (0..$#$names) {
        push @data, {
          group_id => $group_id,
          key => Dongry::Type->serialize ('text', $names->[$_]),
          value => Dongry::Type->serialize ('text', $values->[$_]),
          created => $time,
          updated => $time,
        } if defined $values->[$_];
      }
      if (@data) {
        return $app->db->insert ('group_data', \@data, duplicate => {
          value => $app->db->bare_sql_fragment ('VALUES(`value`)'),
          updated => $app->db->bare_sql_fragment ('VALUES(`updated`)'),
        });
      }
    })->then (sub {
      return $app->send_json ({});
    });
  } # /group/data

  if (@$path == 2 and $path->[1] eq 'touch') {
    ## /group/touch - Update the timestamp of a group
    ##
    ## With
    ##   context_key   An opaque string identifying the application.
    ##                 Required.
    ##   group_id      The group ID.  Required.
    ##   timestamp     The group's updated's new value.  Defaulted to "now".
    ##   force         If true, the group's updated is set to the new
    ##                 value even if it is less than the current value.
    ##
    ## Returns
    ##   changed       If a group is updated, |1|.  Otherwise, |0|.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $time = 0+$app->bare_param ('timestamp') || time;
    my $where = {
      context_key => $app->bare_param ('context_key'),
      group_id => $app->bare_param ('group_id'),
    };
    $where->{updated} = {'<', $time} unless $app->bare_param ('force');
    return $app->db->update ('group', {
      updated => $time,
    }, where => $where)->then (sub {
      my $result = $_[0];
      return $app->send_json ({changed => $result->row_count});
    });
  } # /group/touch

  if (@$path == 2 and $path->[1] eq 'owner_status') {
    ## /group/owner_status - Set the |owner_status| of the group
    ##
    ## With
    ##   context_key    An opaque string identifying the application.  Required.
    ##   group_id      The group ID.  Required.
    ##   owner_status  The new |owner_status| value.  A 7-bit positive integer.
    ##                 Required.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $time = time;
    my $os = $app->bare_param ('owner_status')
        or return $app->throw_error (400, reason_phrase => 'Bad |owner_status|');
    return $app->db->update ('group', {
      owner_status => $os,
      updated => $time,
    }, where => {
      context_key => $app->bare_param ('context_key'),
      group_id => $app->bare_param ('group_id'),
    })->then (sub {
      my $result = $_[0];
      return $app->throw_error (404, reason_phrase => 'Group not found')
          unless $result->row_count == 1;
      return $app->send_json ({});
    });
  } # /group/owner_status

  if (@$path == 2 and $path->[1] eq 'admin_status') {
    ## /group/admin_status - Set the |admin_status| of the group
    ##
    ## With
    ##   context_key    An opaque string identifying the application.  Required.
    ##   group_id      The group ID.  Required.
    ##   admin_status  The new |admin_status| value.  A 7-bit positive integer.
    ##                 Required.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $time = time;
    my $as = $app->bare_param ('admin_status')
        or return $app->throw_error (400, reason_phrase => 'Bad |admin_status|');
    return $app->db->update ('group', {
      admin_status => $as,
      updated => $time,
    }, where => {
      context_key => $app->bare_param ('context_key'),
      group_id => $app->bare_param ('group_id'),
    })->then (sub {
      my $result = $_[0];
      return $app->throw_error (404, reason_phrase => 'Group not found')
          unless $result->row_count == 1;
      return $app->send_json ({});
    });
  } # /group/admin_status

  if (@$path == 2 and $path->[1] eq 'profiles') {
    ## /group/profiles - Get group data
    ##
    ## With
    ##   context_key    An opaque string identifying the application.  Required.
    ##   group_id (0..)      Group IDs
    ##   with_data
    ##   with_icons
    ##
    ## Also, status filters |owner_status| and |admin_status| with
    ## empty prefix are available.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $group_ids = $app->bare_param_list ('group_id')->to_a;
    $_ = unpack 'Q', pack 'Q', $_ for @$group_ids;
    return Promise->resolve->then (sub {
      return [] unless @$group_ids;
      return $app->db->select ('group', {
        context_key => $app->bare_param ('context_key'),
        group_id => {-in => $group_ids},
        (status_filter $app, '', 'owner_status', 'admin_status'),
      }, source_name => 'master', fields => ['group_id', 'created', 'updated', 'admin_status', 'owner_status'])->then (sub {
        return $_[0]->all->to_a;
      });
    })->then (sub {
      return $class->load_data ($app, '', 'group_data', 'group_id', undef, undef, $_[0], 'data');
    })->then (sub {
      return $class->load_icons ($app, 2, 'group_id', $_[0]);
    })->then (sub {
      return $app->send_json ({
        groups => {map {
          $_->{group_id} .= '';
          $_->{group_id} => $_;
        } @{$_[0]}},
      });
    });
  } # /group/profiles


  if (@$path >= 3 and $path->[1] eq 'member') {
    my $context = $app->bare_param ('context_key');
    my $group_id = $app->bare_param ('group_id');
    my $account_id = $app->bare_param ('account_id');
    return Promise->all ([
      $app->db->select ('group', {
        context_key => $context,
        group_id => $group_id,
      }, fields => ['group_id'], source_name => 'master'),
      $app->db->select ('account', {
        account_id => $account_id,
      }, fields => ['account_id'], source_name => 'master'),
    ])->then (sub {
      return $app->throw_error (404, reason_phrase => 'Bad |group_id|')
          unless $_[0]->[0]->first;
      return $app->throw_error (404, reason_phrase => 'Bad |account_id|')
          unless $_[0]->[1]->first;

      if (@$path == 3 and $path->[2] eq 'status') {
        ## /group/member/status - Set status fields of a group member
        ##
        ## With
        ##   context_key   An opaque string identifying the application.
        ##                 Required.
        ##   group_id      A group ID.  Required.
        ##   account_id    An account ID.  Required.
        ##   member_type   New member type.  A 7-bit non-negative integer.
        ##                 Default is "unchanged".
        ##   owner_status  New owner status.  A 7-bit non-negative integer.
        ##                 Default is "unchanged".
        ##   user_status   New user status.  A 7-bit non-negative integer.
        ##                 Default is "unchanged".
        ##
        ## If there is no group member record, a new record is
        ## created.  When a new record is created, the fields are set
        ## to |0| unless otherwise specified.
        $app->requires_request_method ({POST => 1});
        $app->requires_api_key;

        my $mt = $app->bare_param ('member_type');
        my $os = $app->bare_param ('owner_status');
        my $us = $app->bare_param ('user_status');
        my $time = time;
        return $app->db->insert ('group_member', [{
          context_key => $context,
          group_id => $group_id,
          account_id => $account_id,
          created => $time,
          updated => $time,
          member_type => $mt // 0,
          owner_status => $os // 0,
          user_status => $us // 0,
        }], duplicate => {
          updated => $app->db->bare_sql_fragment ('values(`updated`)'),
          (defined $mt ? (member_type => $app->db->bare_sql_fragment ('values(`member_type`)')) : ()),
          (defined $os ? (owner_status => $app->db->bare_sql_fragment ('values(`owner_status`)')) : ()),
          (defined $us ? (user_status => $app->db->bare_sql_fragment ('values(`user_status`)')) : ()),
        })->then (sub {
          return $app->send_json ({});
        });
      } # /group/member/status

      if (@$path == 3 and $path->[2] eq 'data') {
        ## /group/member/data - Write group member data
        ##
        ## With
        ##   context_key   An opaque string identifying the application.
        ##                 Required.
        ##   group_id      A group ID.  Required.
        ##   account_id    An account ID.  Required.
        ##   name (0+)   The keys of data pairs.  A key is an ASCII string.
        ##   value (0+)  The values of data pairs.  There must be same number
        ##               of |value|s as |name|s.  A value is a Unicode string.
        ##               An empty string is equivalent to missing.
        $app->requires_request_method ({POST => 1});
        $app->requires_api_key;

        my $time = time;
        my $names = $app->text_param_list ('name');
        my $values = $app->text_param_list ('value');
        my @data;
        for (0..$#$names) {
          push @data, {
            group_id => $group_id,
            account_id => $account_id,
            key => Dongry::Type->serialize ('text', $names->[$_]),
            value => Dongry::Type->serialize ('text', $values->[$_]),
            created => $time,
            updated => $time,
          } if defined $values->[$_];
        }
        return Promise->resolve->then (sub {
          return unless @data;
          return $app->db->insert ('group_member_data', \@data, duplicate => {
            value => $app->db->bare_sql_fragment ('VALUES(`value`)'),
            updated => $app->db->bare_sql_fragment ('VALUES(`updated`)'),
          });
        })->then (sub {
          return $app->send_json ({});
        });
      } # /group/member/data
    });
  } # /group/member

  if (@$path == 2 and $path->[1] eq 'members') {
    ## /group/members - List of group members
    ##
    ## With
    ##   context_key   An opaque string identifying the application.  Required.
    ##   group_id      A group ID.  Required.
    ##   account_id    An account ID.  Zero or more parameters can be
    ##                 specified.  If specified, only the members with
    ##                 ones of the specified account IDs are returned.
    ##   with_data
    ##
    ## Returns
    ##   memberships   Object of (account_id, group member object)
    ##
    ## Supports paging.
    ##
    ## Also, status filters |user_status| and |owner_status| with
    ## empty prefix are available.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 100, max_limit => 100);
    my $group_id = $app->bare_param ('group_id');
    my $aids = $app->bare_param_list ('account_id')->to_a;
    $_ = unpack 'Q', pack 'Q', $_ for @$aids;
    return $app->db->select ('group_member', {
      context_key => $app->bare_param ('context_key'),
      group_id => $group_id,
      (@$aids ? (account_id => {-in => $aids}) : ()),
      (defined $page->{value} ? (created => $page->{value}) : ()),
      (status_filter $app, '', 'user_status', 'owner_status'),
    }, fields => ['account_id', 'created', 'updated',
                  'user_status', 'owner_status', 'member_type'],
      source_name => 'master',
      offset => $page->{offset}, limit => $page->{limit},
      order => ['created', $page->{order_direction}],
    )->then (sub {
      my $members = $_[0]->all;
      return $class->load_data ($app, '', 'group_member_data', 'account_id', 'group_id' => $group_id, $members, 'data');
    })->then (sub {
      my $members = {map {
        $_->{account_id} .= '';
        ($_->{account_id} => $_);
      } @{$_[0]}};
      my $next_page = next_page $page, $members, 'created';
      return $app->send_json ({memberships => $members, %$next_page});
    });
  } # /group/members

  if (@$path == 2 and $path->[1] eq 'byaccount') {
    ## /group/byaccount - List of groups by account
    ##
    ## With
    ##   context_key   An opaque string identifying the application.  Required.
    ##   account_id    An account ID.  Required.
    ##   with_data
    ##   with_group_data
    ##   with_group_updated : Boolean   Whether the |group_updated|
    ##                                  should be returned or not.
    ##
    ## Returns
    ##   memberships   Object of (group_id, group member object)
    ##
    ##     If |with_group_updated| is true, each group member object
    ##     has |group_updated| field whose value is the group's
    ##     updated.
    ##
    ## Supports paging.
    ##
    ## Also, status filters |user_status| and |owner_status| with
    ## empty prefix are available.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 100, max_limit => 100);
    my $account_id = $app->bare_param ('account_id');
    my $context = $app->bare_param ('context_key');
    return $app->db->select ('group_member', {
      context_key => $context,
      account_id => $account_id,
      (defined $page->{value} ? (updated => $page->{value}) : ()),
      (status_filter $app, '', 'user_status', 'owner_status'),
    }, fields => ['group_id', 'created', 'updated',
                  'user_status', 'owner_status', 'member_type'],
      source_name => 'master',
      offset => $page->{offset}, limit => $page->{limit},
      order => ['updated', $page->{order_direction}],
    )->then (sub {
      my $groups = $_[0]->all;
      return $class->load_data ($app, '', 'group_member_data', 'group_id', 'account_id' => $account_id, $groups, 'data');
    })->then (sub {
      return $class->load_data ($app, 'group_', 'group_data', 'group_id', undef, undef, $_[0], 'group_data');
    })->then (sub {
      my $groups = $_[0];
      return $groups unless $app->bare_param ('with_group_updated');
      return $groups unless @$groups;
      return $app->db->select ('group', {
        context_key => $context,
        group_id => {-in => [map { $_->{group_id} } @$groups]},
        # status filters not applied here (for now, at least)
      }, fields => ['group_id', 'updated'], source_name => 'master')->then (sub {
        my $g2u = {};
        for (@{$_[0]->all}) {
          $g2u->{$_->{group_id}} = $_->{updated};
        }
        for (@$groups) {
          $_->{group_updated} = $g2u->{$_->{group_id}};
        }
        return $groups;
      });
    })->then (sub {
      my $groups = {map {
        $_->{group_id} .= '';
        ($_->{group_id} => $_);
      } @{$_[0]}};
      my $next_page = next_page $page, $groups, 'updated';
      return $app->send_json ({memberships => $groups, %$next_page});
    });
  } # /group/byaccount

  if (@$path == 2 and $path->[1] eq 'list') {
    ## /group/list - List of groups
    ##
    ## With
    ##   context_key   An opaque string identifying the application.  Required.
    ##   with_data
    ##
    ## Returns
    ##   groups        Object of (group_id, group object)
    ##
    ## Supports paging
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 100, max_limit => 100);
    my $account_id = $app->bare_param ('account_id');
    return $app->db->select ('group', {
      context_key => $app->bare_param ('context_key'),
      (defined $page->{value} ? (updated => $page->{value}) : ()),
      (status_filter $app, '', 'owner_status', 'admin_status'),
    }, source_name => 'master',
      fields => ['group_id', 'created', 'updated', 'admin_status', 'owner_status'],
      offset => $page->{offset}, limit => $page->{limit},
      order => ['updated', $page->{order_direction}],
    )->then (sub {
      return $_[0]->all->to_a;
    })->then (sub {
      return $class->load_data ($app, '', 'group_data', 'group_id', undef, undef, $_[0], 'data');
    })->then (sub {
      my $groups = {map {
        $_->{group_id} .= '';
        ($_->{group_id} => $_);
      } @{$_[0]}};
      my $next_page = next_page $page, $groups, 'updated';
      return $app->send_json ({
        groups => $groups,
        %$next_page,
      });
    });
  } # /group/list

  return $app->throw_error (404);
} # group

sub invite ($$$) {
  my ($class, $app, $path) = @_;

  if (@$path == 2 and $path->[1] eq 'create') {
    ## /invite/create - Create an invitation
    ##
    ## Parameters
    ##   context_key   An opaque string identifying the application.  Required.
    ##   invitation_context_key An opaque string identifying the kind
    ##                 or target of the invitation.  Required.
    ##   account_id    The ID of the account who creates the invitation.
    ##                 Required.  This must be a valid account ID (not
    ##                 verified by the end point).
    ##   data          A JSON data packed within the invitation.  Default
    ##                 is |null|.
    ##   expires       The expiration date of the invitation, in Unix time
    ##                 number.  Default is now + 24 hours.
    ##   target_account_id The ID of the account who can use the invitation.
    ##                 Default is |0|, which indicates the invitation can
    ##                 be used by anyone.  Otherwise, this must be a valid
    ##                 account ID (not verified by the end point).
    ##
    ## Returns
    ##   context_key   Same as parameter, echoed just for convenience.
    ##   invitation_context_key Same as parameter, echoed just for convenience.
    ##   invitation_key An opaque string identifying the invitation.
    ##
    ##   expires : Timestamp     The invitation's expiration time.
    ##
    ##   timestamp : Timestamp   The invitation's created time.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $context_key = $app->bare_param ('context_key')
        // return $app->throw_error (400, reason_phrase => 'No |context_key|');
    my $inv_context_key = $app->bare_param ('invitation_context_key')
        // return $app->throw_error (400, reason_phrase => 'No |invitation_context_key|');
    my $author_account_id = $app->bare_param ('account_id')
        or return $app->throw_error (400, reason_phrase => 'No |account_id|');
    my $data = Dongry::Type->parse ('json', $app->bare_param ('data'));
    my $invitation_key = id 30;
    my $time = time;
    my $expires = $app->bare_param ('expires');
    $expires = $time + 24*60*60 unless defined $expires;
    return $app->db->insert ('invitation', [{
      context_key => $context_key,
      invitation_context_key => $inv_context_key,
      invitation_key => $invitation_key,
      author_account_id => $author_account_id,
      invitation_data => Dongry::Type->serialize ('json', $data) // 'null',
      target_account_id => $app->bare_param ('target_account_id') || 0,
      created => $time,
      expires => $expires,
      user_account_id => 0,
      used_data => 'null',
      used => 0,
    }])->then (sub {
      return $app->send_json ({
        context_key => $context_key,
        invitation_context_key => $inv_context_key,
        invitation_key => $invitation_key,
        timestamp => $time,
        expires => $expires,
      });
    });
  } # /invite/create

  if (@$path == 2 and $path->[1] eq 'use') {
    ## /invite/use - Use an invitation
    ##
    ## Parameters
    ##   context_key   An opaque string identifying the application.  Required.
    ##   invitation_context_key An opaque string identifying the kind
    ##                 or target of the invitation.  Required.
    ##   invitation_key An opaque string identifying the invitation.  Required.
    ##   account_id    The ID of the account who uses the invitation.
    ##                 Required unless |ignore_target| is true.  If missing,
    ##                 defaulted to zero.
    ##                 This must be a valid account ID (not verified by the
    ##                 end point).
    ##   ignore_target If true, target account of the invitation is ignored.
    ##                 This parameter can be used to disable the invitation
    ##                 (e.g. by the owner of the target resource).
    ##   data          A JSON data saved with the invitation.  Default
    ##                 is |null|.
    ##
    ## Returns
    ##   invitation_data The JSON data saved when the invitation was created.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $context_key = $app->bare_param ('context_key')
        // return $app->throw_error (400, reason_phrase => 'Bad |context_key|');
    my $inv_context_key = $app->bare_param ('invitation_context_key')
        // return $app->throw_error (400, reason_phrase => 'Bad |invitation_context_key|');
    my $invitation_key = $app->bare_param ('invitation_key')
        // return $app->throw_error_json ({reason => 'Bad |invitation_key|'});
    my $ignore_target = $app->bare_param ('ignore_target');
    my $user_account_id = $app->bare_param ('account_id')
        or $ignore_target
        or return $app->throw_error (400, reason_phrase => 'No |account_id|');
    $user_account_id = unpack 'Q', pack 'Q', $user_account_id if defined $user_account_id;
    my $data = Dongry::Type->parse ('json', $app->bare_param ('data'));
    my $time = time;
    return $app->db->update ('invitation', {
      user_account_id => $user_account_id // 0,
      used_data => Dongry::Type->serialize ('json', $data) // 'null',
      used => $time,
    }, where => {
      context_key => $context_key,
      invitation_context_key => $inv_context_key,
      invitation_key => $invitation_key,
      ($ignore_target ? () : (target_account_id => {-in => [0, $user_account_id]})),
      expires => {'>=', $time},
      used => 0,
    })->then (sub {
      unless ($_[0]->row_count == 1) {
        ## Either:
        ##   - Invitation key is invalid
        ##   - context_key or invitation_context_key is wrong
        ##   - The account is not the target of the invitation
        ##   - The invitation has expired
        ##   - The invitation has been used
        return $app->throw_error_json ({reason => 'Bad invitation'});
      }
      return $app->db->select ('invitation', {
        context_key => $context_key,
        invitation_context_key => $inv_context_key,
        invitation_key => $invitation_key,
      }, fields => ['invitation_data'], source_name => 'master');
    })->then (sub {
      my $d = $_[0]->first // die "Invitation not found";
      return $app->send_json ({
        invitation_data => Dongry::Type->parse ('json', $d->{invitation_data}),
      });
    });
  } # /invite/use

  if (@$path == 2 and $path->[1] eq 'open') {
    ## /invite/open - Get an invitation for recipient
    ##
    ## Parameters
    ##   context_key   An opaque string identifying the application.  Required.
    ##   invitation_context_key An opaque string identifying the kind
    ##                 or target of the invitation.  Required.
    ##   invitation_key An opaque string identifying the invitation.  Required.
    ##   account_id    The ID of the account who reads the invitation.
    ##                 Can be |0| for "anyone".  Required.  This must be
    ##                 a valid account ID (not verified by the end point).
    ##   with_used_data : Boolean If true, |used_data| is returned, if any.
    ##
    ## Returns
    ##   author_account_id
    ##   invitation_data The JSON data saved when the invitation was created.
    ##   target_account_id
    ##   created
    ##   expires
    ##   used
    ##   used_data : Object?
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $context_key = $app->bare_param ('context_key');
    my $inv_context_key = $app->bare_param ('invitation_context_key');
    my $invitation_key = $app->bare_param ('invitation_key');
    my $user_account_id = unpack 'Q', pack 'Q', ($app->bare_param ('account_id') || 0);
    my $wud = $app->bare_param ('with_used_data');
    return $app->db->select ('invitation', {
      context_key => $context_key,
      invitation_context_key => $inv_context_key,
      invitation_key => $invitation_key,
      target_account_id => {-in => [0, $user_account_id]},
    }, fields => [
      'author_account_id', 'invitation_data',
      'target_account_id', 'created', 'expires',
      'used', ($wud ? 'used_data' : ()),
    ], source_name => 'master')->then (sub {
      my $d = $_[0]->first
          // return $app->throw_error_json ({reason => 'Bad invitation'});
      $d->{invitation_key} = $invitation_key;
      $d->{invitation_data} = Dongry::Type->parse ('json', $d->{invitation_data});
      $d->{used_data} = Dongry::Type->parse ('json', $d->{used_data})
          if defined $d->{used_data};
      return $app->send_json ($d);
    });
  } # /invite/open

  if (@$path == 2 and $path->[1] eq 'list') {
    ## /invite/list - Get invitations for owners
    ##
    ## Parameters
    ##   context_key             An opaque string identifying the application.
    ##                           Required.
    ##   invitation_context_key  An opaque string identifying the kind
    ##                           or target of the invitation.  Required.
    ##   unused : Boolean        If specified, only invitations whose used is
    ##                           false is returned.
    ##
    ## Returns
    ##   invitations   Object of (invitation_key, inivitation object)
    ##
    ## Supports paging.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 50, max_limit => 100);
    my $context_key = $app->bare_param ('context_key');
    my $inv_context_key = $app->bare_param ('invitation_context_key');
    return $app->db->select ('invitation', {
      context_key => $context_key,
      invitation_context_key => $inv_context_key,
      (defined $page->{value} ? (created => $page->{value}) : ()),
      ($app->bare_param ('unused') ? (used => 0) : ()),
    }, fields => ['invitation_key', 'author_account_id', 'invitation_data',
                   'target_account_id', 'created', 'expires',
                   'used', 'used_data', 'user_account_id'],
      source_name => 'master',
      offset => $page->{offset}, limit => $page->{limit},
      order => ['created', $page->{order_direction}],
    )->then (sub {
      my $items = $_[0]->all->to_a;
      for (@$items) {
        $_->{invitation_data} = Dongry::Type->parse ('json', $_->{invitation_data});
        $_->{used_data} = Dongry::Type->parse ('json', $_->{used_data});
        $_->{author_account_id} .= '';
        $_->{target_account_id} .= '';
        $_->{user_account_id} .= '';
      }
      my $next_page = next_page $page, $items, 'created';
      return $app->send_json ({invitations => {map { $_->{invitation_key} => $_ } @$items}, %$next_page});
    });
  } # /invite/list

  return $app->throw_error (404);
} # invite

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
