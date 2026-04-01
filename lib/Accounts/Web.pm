package Accounts::Web;
use strict;
use warnings;
use Time::HiRes qw(time);
use Promise;
use Promised::File;
use Promised::Command;
use JSON::PS;
use Wanage::URL;
use Wanage::HTTP;
use Dongry::Type;
use Dongry::Type::JSONPS;
use Dongry::SQL qw(like);

sub format_id ($) {
  return sprintf '%llu', $_[0];
} # format_id

## Some end points accept "status filter" parameters.  If an end point
## accepts status filter for field /f/ with prefix /p/, the end points
## can receive parameters whose name is /p//f/.  If one or more
## parameter values with that name are specified, only items whose
## field /f/'s value is one of those parameter values are returned.
## Otherwise, any available item is returned.
##
## For example, /info accepts |group_owner_status| parameter for field
## |owner_status| with prefix |group_|.  If
## |group_owner_status=1&group_owner_status=2| is specified, only
## items whose |owner_status| is |1| or |2| are returned.  If no
## |group_owner_status| parameter is specified, all items are
## returned.
sub status_filter ($$@) {
  my ($app, $prefix, @name) = @_;
  my $result = {};
  for my $name (@name) {
    my $values = $app->bare_param_list ($prefix . $name);
    $result->{$name} = {-in => $values} if @$values;
  }
  return %$result;
} # status_filter

my $DEBUG = $ENV{ACCOUNTS_DEBUG};

sub psgi_app ($$) {
  my ($class, $config) = @_;
  return sub {
    ## This is necessary so that different forked siblings have
    ## different seeds.
    srand;

    ## XXX Parallel::Prefork (?)
    delete $SIG{CHLD};
    delete $SIG{CLD};

    my $http = Wanage::HTTP->new_from_psgi_env ($_[0]);
    my $app = Accounts::AppServer->new_from_http_and_config ($http, $config);

    my $start_time = time;
    my $access_id = int rand 1000000;
    warn sprintf "Access[%d]: [%s] %s %s\n",
        $access_id, scalar gmtime $start_time,
        $app->http->request_method, $app->http->url->stringify
        if $DEBUG;

    return $app->execute_by_promise (sub {
      return Promise->resolve->then (sub {
        return $class->main ($app);
      })->then (sub {
        return $app->shutdown;
      }, sub {
        my $error = $_[0];
        return $app->shutdown->then (sub { die $error });
      })->catch (sub {
        return if UNIVERSAL::isa ($_[0], 'Warabe::App::Done');
        $app->error_log ($_[0]);
        die $_[0];
      })->finally (sub {
        return unless $DEBUG;
        warn sprintf "Access[%d]: %f s\n",
            $access_id, time - $start_time;
      });
    });
  };
} # psgi_app

## If an end point supports paging, following parameters are
## available:
##   ref       A short string identifying the page
##   limit     The maximum number of the returned items (i.e. page size)
##
## If the processing of the end point has succeeded, the result JSON
## has following fields:
##   has_next  Whether there is next page or not (at the time of the operation)
##   next_ref  The |ref| parameter value for the next page

sub this_page ($%) {
  my ($app, %args) = @_;
  my $page = {
    order_direction => 'DESC',
    limit => 0+($app->bare_param ('limit') // $args{limit} // 30),
    offset => 0,
    value => undef,
  };
  my $max_limit = $args{max_limit} // 100;
  return $app->throw_error_json ({reason => "Bad |limit|"})
      if $page->{limit} < 1 or $page->{limit} > $max_limit;
  my $ref = $app->bare_param ('ref');
  if (defined $ref) {
    if ($ref =~ /\A([+-])([0-9.]+),([0-9]+)\z/) {
      $page->{order_direction} = $1 eq '+' ? 'ASC' : 'DESC';
      $page->{exact_value} = 0+$2;
      $page->{value} = {($page->{order_direction} eq 'ASC' ? '>=' : '<='), $page->{exact_value}};
      $page->{offset} = 0+$3;
      return $app->throw_error_json ({reason => "Bad |ref| offset"})
          if $page->{offset} > 100;
      $page->{ref} = $ref;
    } else {
      return $app->throw_error_json ({reason => "Bad |ref|"});
    }
  }
  return $page;
} # this_page

sub next_page ($$$) {
  my ($this_page, $items, $value_key) = @_;
  my $next_page = {};
  my $sign = $this_page->{order_direction} eq 'ASC' ? '+' : '-';
  my $values = {};
  $values->{$this_page->{exact_value}} = $this_page->{offset}
      if defined $this_page->{exact_value};
  if (ref $items eq 'ARRAY') {
    if (@$items) {
      my $last_value = $items->[0]->{$value_key};
      for (@$items) {
        $values->{$_->{$value_key}}++;
        if ($sign eq '+') {
          $last_value = $_->{$value_key} if $last_value < $_->{$value_key};
        } else {
          $last_value = $_->{$value_key} if $last_value > $_->{$value_key};
        }
      }
      $next_page->{next_ref} = $sign . $last_value . ',' . $values->{$last_value};
      $next_page->{has_next} = @$items == $this_page->{limit};
    } else {
      $next_page->{next_ref} = $this_page->{ref};
      $next_page->{has_next} = 0;
    }
  } else { # HASH
    if (keys %$items) {
      my $last_value = $items->{each %$items}->{$value_key};
      for (values %$items) {
        $values->{$_->{$value_key}}++;
        if ($sign eq '+') {
          $last_value = $_->{$value_key} if $last_value < $_->{$value_key};
        } else {
          $last_value = $_->{$value_key} if $last_value > $_->{$value_key};
        }
      }
      $next_page->{next_ref} = $sign . $last_value . ',' . $values->{$last_value};
      $next_page->{has_next} = (keys %$items) == $this_page->{limit};
    } else {
      $next_page->{next_ref} = $this_page->{ref};
      $next_page->{has_next} = 0;
    }
  }
  return $next_page;
} # next_page

{
  my @alphabet = ('A'..'Z', 'a'..'z', 0..9);
  sub id ($) {
    my $key = '';
    $key .= $alphabet[rand @alphabet] for 1..$_[0];
    return $key;
  } # id
}

use Accounts::AppServer;
use Accounts::Web::Login;
use Accounts::Web::Groups;
use Accounts::Web::Media;

my $MaxSessionTimeout = 60*60*24*10;

## Operation source parameters.
##
##   |source_ua|     : Bytes :  The source |User-Agent| header, if any.
##   |source_ipaddr| : Bytes :  The source IP address, if any.
##   |source_data|   : JSON :   Application-dependent source data, if any.
##

sub main ($$) {
  my ($class, $app) = @_;
  my $path = $app->path_segments;

  $app->http->response_timing_enabled
      ($app->http->get_request_header ('x-timing'));
  $app->db->connect ('master'); # preconnect

  if ({
    login => 1, link => 1, cb => 1, email => 1, keygen => 1, token => 1,
    create => 1,
  }->{$path->[0]}) {
    return Accounts::Web::Login->login ($app, $path);
  }

  if ($path->[0] eq 'group') {
    return Accounts::Web::Groups->group ($app, $path);
  }

  if ($path->[0] eq 'invite') {
    return Accounts::Web::Groups->invite ($app, $path);
  }

  if ($path->[0] eq 'icon') {
    return Accounts::Web::Media->icon ($app, $path);
  }

  if (@$path == 1 and $path->[0] eq 'session') {
    ## /session - Ensure that there is a session
    ##
    ## Parameters
    ##
    ##   Operation source parameters.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $sk = $app->bare_param ('sk') // '';
    my $sk_context = $app->bare_param ('sk_context')
        // return $app->throw_error_json ({reason => 'No |sk_context|'});
    my $time = time;
    return ((length $sk ? $app->db->select ('session', {
      sk => $sk,
      sk_context => $sk_context,
      expires => {'>', time},
    }, fields => ['sk', 'sk_context', 'expires', 'data'], source_name => 'master')->then (sub {
      return $_[0]->first_as_row; # or undef
    }) : Promise->resolve (undef))->then (sub {
      my $session_row = $_[0];
      if (defined $session_row) {
        my $session_data = $session_row->get ('data');
        if (defined $session_data->{session_id}) { # sessions before R5.10.3 does not have |session_id|
          return [$session_row, 0];
        }
      }

      $sk = id 100;
      my $age = $MaxSessionTimeout;
      my $ma = $app->config->get ('session_max_age') || 'Infinity';
      $age = $ma if $ma < $age;
      return $app->db->uuid_short (1)->then (sub {
        my $session_id = $_[0]->[0];
        my $data = {session_id => '' . $session_id};
        return $app->db->insert ('session', [{
          sk => $sk,
          sk_context => $sk_context,
          created => $time,
          expires => $time + $age,
          data => Dongry::Type->serialize ('json', $data),
        }], source_name => 'master');
      })->then (sub {
        $session_row = $_[0]->first_as_row;
        return [$session_row, 1];
      });
    })->then (sub {
      my ($session_row, $new) = @{$_[0]};
      my $json = {sk => $session_row->get ('sk'),
                  sk_expires => $session_row->get ('expires'),
                  set_sk => $new?1:0};
      $app->send_json ($json);
      return $class->write_session_log ($app, $session_row, $time, force => 1);
    })->then (sub {
      return $class->delete_old_sessions ($app);
    }));
  } elsif (@$path == 2 and $path->[0] eq 'session' and $path->[1] eq 'get') {
    ## /session/get - Get a list of sessions
    ##
    ## Parameters
    ##
    ##   |use_sk|, |sk|, |sk_context|, |sk_max_age|
    ##   |account_id| : ID      : The sessions' account's ID.
    ##   Either |sk| and its family or |account_id| is required.
    ##
    ##   |session_sk_context| : String* : The sessions' |sk_context|.
    ##                            Zero or more parameters can be specified.
    ##
    ## Returns
    ##
    ##   |items| : Array<Session> : An array of sessions.
    ##
    ## Supports paging.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 50, max_limit => 100);
    my $where = {};
    $where->{timestamp} = $page->{value} if defined $page->{value};
    my $sk_contexts = $app->bare_param_list ('session_sk_context')->to_a;
    $where->{sk_context} = {-in => $sk_contexts} if @$sk_contexts;

    return Promise->resolve->then (sub {
      if ($app->bare_param ('use_sk')) {
        return $app->throw_error
            (400, reason_phrase => 'Both |sk| and |account_id| is specified')
            if defined $app->bare_param ('account_id');
        return $class->resume_session ($app)->then (sub {
          my $session_row = $_[0];
          if (defined $session_row) {
            my $session_data = $session_row->get ('data');
            if (defined $session_data->{account_id}) {
              $where->{account_id} = 0+$session_data->{account_id};
            } else {
              $where->{sk} = $session_row->get ('sk');
              $where->{sk_context} //= $session_row->get ('sk_context');
                  ## Any |session_sk_context| is preferred here.  As |sk|
                  ## is globally unique, if |session_sk_context| does not
                  ## have session's |sk_context|, no log is returned.
            }
            return 1;
          } else {
            return 0;
          }
        });
      } else {
        $where->{account_id} = $app->bare_param ('account_id');
        return $app->throw_error_json ({reason => 'No |account_id|'})
            if not defined $where->{account_id};
        return 1;
      }
    })->then (sub {
      return undef if not $_[0];
      return $app->db->select ('session_recent_log', $where,
        fields => ['session_id', 'sk_context', 'timestamp', 'expires', 'data'],
        source_name => 'master',
        offset => $page->{offset}, limit => $page->{limit},
        order => ['timestamp', $page->{order_direction}],
      );
    })->then (sub {
      my $v = $_[0];
      my $items = [map {
        $_->{session_id} .= '';
        $_->{log_data} = Dongry::Type->parse ('json', delete $_->{data});
        $_;
      } defined $v ? $v->all->to_list : ()];
      my $next_page = next_page $page, $items, 'timestamp';
      return $app->send_json ({
        items => $items,
        %$next_page,
      });
    });
  } elsif (@$path == 2 and $path->[0] eq 'session' and $path->[1] eq 'delete') {
    ## /session/delete - Delete a session
    ##
    ## Parameters
    ##
    ##   |sk|, |sk_context|, |sk_max_age|
    ##   |use_sk|     : Boolean : If true, |sk| and its family is used
    ##                          to determine whether the delete operation
    ##                          is performed or not.
    ##
    ##   |session_sk_context| : String? : The session's sk_context.
    ##   |session_id| : ID?   : The session's session ID.
    ##
    ## Returns nothing.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $where = {};
    return Promise->resolve->then (sub {
      if ($app->bare_param ('use_sk')) {
        return $class->resume_session ($app)->then (sub {
          my $session_row = $_[0];
          if (defined $session_row) {
            $where->{sk} = $session_row->get ('sk');
            $where->{sk_context} = $session_row->get ('sk_context');
            my $session_data = $session_row->get ('data');
            $where->{account_id} = 0+($session_data->{account_id} || 0);
            return 1;
          } else {
            return 0;
          }
        });
      } else {
        return 1;
      }
    })->then (sub {
      return unless $_[0];
      
      my $sid = $app->bare_param ('session_id');
      if (defined $sid) {
        $where->{session_id} = $sid;
        delete $where->{sk} if $where->{account_id};
      }
      my $sc = $app->bare_param ('session_sk_context');
      $where->{sk_context} = $sc if defined $sc;

      if (not defined $where->{sk}) {
        return $app->throw_error_json ({reason => 'No |session_id|'})
            unless defined $where->{session_id};
        return $app->db->select ('session_recent_log', $where, source_name => 'master', fields => ['sk', 'sk_context'])->then (sub {
          my $v = $_[0]->first;
          if (defined $v) {
            $where->{sk} = $v->{sk};
            $where->{sk_context} //= $v->{sk_context};
            return $app->db->delete ('session_recent_log', $where, source_name => 'master', limit => 1)->then (sub {
              my $v = $_[0];
              if ($v->row_count or not defined $where->{session_id}) {
                delete $where->{session_id};
                delete $where->{account_id};
                return $app->db->delete ('session', $where, source_name => 'master', limit => 1);
              }
            });
          }
        });
      } else {
        return $app->db->delete ('session_recent_log', $where, source_name => 'master', limit => 1)->then (sub {
          my $v = $_[0];
          if ($v->row_count or not defined $where->{session_id}) {
            delete $where->{session_id};
            delete $where->{account_id};
            return $app->db->delete ('session', $where, source_name => 'master', limit => 1);
          }
        });
      }
    })->then (sub {
      return $app->send_json ({});
    });
  } # /session/delete
  
  if (@$path == 2 and $path->[0] eq 'ticket' and $path->[1] eq 'add') {
    ## /ticket/add - Add a ticket to the session
    ##
    ##   |sk_context|, |sk|
    ##   |ticket| : Key :           The ticket.  Zero or more parameters
    ##                              can be specified.
    ##
    ## Returns nothing.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0]
          // return $app->throw_error_json
                 ({reason => 'Bad session',
                   error_for_dev => "/ticket/add bad session"});
      my $session_data = $session_row->get ('data');
      
      my $tickets = $app->bare_param_list ('ticket');
      $session_data->{tickets}->{$_} = 1 for @$tickets;
      return $session_row->update
          ({data => $session_data}, source_name => 'master');
    })->then (sub {
      return $app->send_json ({});
    });
  } # /ticket/add

  if (@$path == 1 and $path->[0] eq 'info') {
    ## /info - Get the current account of the session
    ##
    ## Parameters
    ##   sk           The |sk| value of the sesion, if available
    ##   context_key  An opaque string identifying the application.
    ##                Required when |group_id| is specified.
    ##   group_id     The group ID.  If specified, properties of group and
    ##                group membership of the account of the session are
    ##                also returned.
    ##   additional_group_id Additional group ID.  Zero or more options
    ##                can be specified.  If specified, group memberships
    ##                of the account of the session for these groups
    ##                are also returned.  Ignored when |group_id| is not
    ##                specified.
    ##   additional_group_data Name of data whose value is an additional
    ##                group ID.  Zero or more options can be specified.
    ##                If specified, group memberships of the account
    ##                of the session for these groups are also returned.
    ##                Ignored when |group_id| is not specified, the
    ##                group data is not loaded by |with_group_data|
    ##                option, there is no such data, or the value is not a
    ##                group ID.
    ##   with_data
    ##   with_group_data Data of the group.  Not applicable to additional
    ##                groups.
    ##   with_group_member_data Data of the group's membership.  Not
    ##                applicable to additional groups.
    ##   with_agm_group_data Data of the additional group members' group's
    ##                data.
    ##   with_tickets : Boolean : If true, session's tickets are returned.
    ##
    ## Also, status filters |user_status|, |admin_status|,
    ## |terms_version| with empty prefix are available for account
    ## data.
    ##
    ## Status filters |owner_status| and |admin_status| with prefix
    ## |group_| are available for group and additional group objects.
    ##
    ## Status filters |user_status|, |owner_status|, |member_type|
    ## with prefix |group_membership_| are available for group
    ## membership object.
    ##
    ## Returns
    ##   account_id   The account ID, if there is an account.
    ##   name         The name of the account, if there is an account.
    ##   user_status  The user status of the account, if there is.
    ##   admin_status The admin status of the account, if there is.
    ##   terms_version The terms version of the account, if there is.
    ##   group        The group object, if available.
    ##   group_membership The group membership object, if available.
    ##   login_time : Timestamp? : The last login time of the session,
    ##                             if applicable.
    ##   no_email : Boolean : If true, there is an account but no account
    ##                        link with service name |email|.  Note that
    ##                        the value might be out of sync when modified.
    ##   additional_group_memberships : Object?
    ##     /group_id/  Additional group's membership object, if available.
    ##       group_data  Group data of the membership's group, if applicable.
    ##   tickets : Object? :  If |with_tickets|, an object whose names are
    ##                        tickets.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $st_all = $app->http->response_timing ("all");
    my $st_re = $app->http->response_timing ("resume");
    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      $st_re->add;
      my $context_key = $app->bare_param ('context_key');
      my $group_id = $app->bare_param ('group_id');
      my $json = {};
      return Promise->resolve->then (sub {
        return unless defined $group_id;
        return $app->db->select ('group', {
          context_key => $context_key,
          group_id => $group_id,
          (status_filter $app, 'group_', 'admin_status', 'owner_status'),
        }, fields => ['group_id', 'created', 'updated', 'owner_status', 'admin_status'], source_name => 'master')->then (sub {
          my $g = $_[0]->first // return;
          $g->{group_id} .= '';
          $group_id = $g->{group_id};
          $json->{group} = $g;
          return $class->load_data ($app, 'group_', 'group_data', 'group_id', undef, undef, [$json->{group}], 'data');
        });
      })->then (sub {
        my $account_id;
        my $session_data;
        if (defined $session_row) {
          $session_data = $session_row->get ('data');
          $account_id = $session_data->{account_id};

          if ($app->bare_param ('with_tickets')) {
            $json->{tickets} = $session_data->{tickets} || {};
          }
        }
        return unless defined $account_id;
        
        my $st = $app->http->response_timing ("acc");
        return $app->db->select ('account', {
          account_id => Dongry::Type->serialize ('text', $account_id),
          (status_filter $app, '', 'user_status', 'admin_status', 'terms_version'),
        }, source_name => 'master', fields => ['name', 'user_status', 'admin_status', 'terms_version'])->then (sub {
          my $r = $_[0]->first_as_row;
          $st->add;
          return unless defined $r;
          $json->{account_id} = format_id $account_id;
          $json->{name} = $r->get ('name');
          $json->{user_status} = $r->get ('user_status');
          $json->{admin_status} = $r->get ('admin_status');
          $json->{terms_version} = $r->get ('terms_version');
          $json->{login_time} = $session_data->{login_time};
          $json->{no_email} = 1 if $session_data->{no_email};
          
          if (defined $context_key and defined $group_id) {
              my $add_group_ids = $app->bare_param_list
                  ('additional_group_id');
              if (defined $json->{group}) {
                my $add_group_data_names = $app->bare_param_list
                    ('additional_group_data');
                for my $name (@$add_group_data_names) {
                  if (defined $json->{group}->{data}->{$name} and
                      $json->{group}->{data}->{$name} =~ /\A[1-9][0-9]*\z/) {
                    push @$add_group_ids, unpack 'Q', pack 'Q', $json->{group}->{data}->{$name};
                  }
                }
              }
              my $st = $app->http->response_timing ("gr");
              return $app->db->select ('group_member', {
                context_key => $context_key,
                group_id => {-in => [$group_id, @$add_group_ids]},
                account_id => Dongry::Type->serialize ('text', $account_id),
                (status_filter $app, 'group_membership_', 'user_status', 'owner_status', 'member_type'),
              }, fields => [
                'group_id', 'user_status', 'owner_status', 'member_type',
              ], source_name => 'master')->then (sub {
                my $group_id_to_data = {};
                for (@{$_[0]->all}) {
                  $group_id_to_data->{$_->{group_id}} = $_;
                  $_->{group_id} .= '';
                }
                $st->add;
                if (defined $group_id_to_data->{$group_id}) {
                  $json->{group_membership} = $group_id_to_data->{$group_id};
                }
                for (@$add_group_ids) {
                  $json->{additional_group_memberships}->{$_} = $group_id_to_data->{$_}
                      if defined $group_id_to_data->{$_};
                }
              });
            }
          });
      })->then (sub {
        return $class->load_linked ($app => [$json]);
      })->then (sub {
        my $st = $app->http->response_timing ("accd");
        return $class->load_data ($app, '', 'account_data', 'account_id', undef, undef, [$json], 'data')->then (sub {
          $st->add;
        });
      })->then (sub {
        delete $json->{group_membership} if not defined $json->{group};
        return unless defined $json->{group_membership};
        my $st = $app->http->response_timing ("grmd");
        return $class->load_data ($app, 'group_member_', 'group_member_data', 'group_id', 'account_id', $json->{account_id}, [$json->{group_membership}], 'data')->then (sub {
          $st->add;
        });
      })->then (sub {
        my $st = $app->http->response_timing ("grd");
        return $class->load_data ($app, 'agm_group_', 'group_data', 'group_id', undef, undef, [values %{$json->{additional_group_memberships} or {}}], 'group_data')->then (sub {
          $st->add;
        });
      })->then (sub {
        return $app->send_json ($json, server_timing => $st_all);
      });
    });
  } # /info

  if (@$path == 1 and $path->[0] eq 'profiles') {
    ## /profiles - Account data
    ##
    ## Parameters
    ## 
    ##   account_id (0..)   Account IDs
    ##   with_data
    ##   with_linked
    ##   with_icons
    ##   with_statuses : Boolean  : Whether the account's status fields
    ##                              should be included to the output or not.
    ##
    ## Also, status filters |user_status|, |admin_status|,
    ## |terms_version| with empty prefix are available.
    ##
    ## Returns an object where names are account IDs and values are
    ## accounts' data.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $account_ids = $app->bare_param_list ('account_id')->to_a;
    $_ = unpack 'Q', pack 'Q', $_ for @$account_ids;
    my $ws = $app->bare_param ('with_statuses');
    return ((@$account_ids ? $app->db->select ('account', {
      account_id => {-in => $account_ids},
      (status_filter $app, '', 'user_status', 'admin_status', 'terms_version'),
    }, source_name => 'master', fields => [
      'account_id', 'name',
      ($ws ? qw(user_status admin_status terms_version) : ()),
    ])->then (sub {
      return $_[0]->all_as_rows->to_a;
    }) : Promise->resolve ([]))->then (sub {
      return $class->load_linked ($app, [map {
        +{
          account_id => format_id $_->get ('account_id'),
          name => $_->get ('name'),
          ($ws ? (
            user_status => $_->get ('user_status'),
            admin_status => $_->get ('admin_status'),
            terms_version => $_->get ('terms_version'),
          ) : ()),
        };
      } @{$_[0]}]);
    })->then (sub {
      return $class->load_data ($app, '', 'account_data', 'account_id', undef, undef, $_[0], 'data');
    })->then (sub {
      return $class->load_icons ($app, 1, 'account_id', $_[0]);
    })->then (sub {
      return $app->send_json ({
        accounts => {map { $_->{account_id} => $_ } @{$_[0]}},
      });
    }));
  } # /profiles

  if (@$path == 1 and $path->[0] eq 'data') {
    ## /data - Account data
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      my $account_id = defined $session_row ? $session_row->get ('data')->{account_id} : undef;

      return $app->send_error_json ({reason => 'Not a login user'})
          unless defined $account_id;

      my $names = $app->text_param_list ('name');
      my $values = $app->text_param_list ('value');
      my @data;
      for (0..$#$names) {
        push @data, {
          account_id => Dongry::Type->serialize ('text', $account_id),
          key => Dongry::Type->serialize ('text', $names->[$_]),
          value => Dongry::Type->serialize ('text', $values->[$_]),
          created => time,
          updated => time,
        } if defined $values->[$_];
      }
      if (@data) {
        return $app->db->insert ('account_data', \@data, duplicate => {
          value => $app->db->bare_sql_fragment ('VALUES(`value`)'),
          updated => $app->db->bare_sql_fragment ('VALUES(updated)'),
        })->then (sub {
          return $app->send_json ({});
        });
      } else {
        return $app->send_json ({});
      }
    });
  } # /data

  if (@$path == 1 and $path->[0] eq 'agree') {
    ## /agree - Agree with terms
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    return $class->resume_session ($app)->then (sub {
      my $session_row = $_[0];
      my $account_id = defined $session_row ? Dongry::Type->serialize ('text', $session_row->get ('data')->{account_id}) : undef;
      return $app->send_error_json ({reason => 'Not a login user'})
          unless defined $account_id;

      my $version = 0+($app->bare_param ('version') || 0);
      $version = 255 if $version > 255;
      my $dg = $app->bare_param ('downgrade');
      return Promise->all ([
        $app->db->execute ('UPDATE `account` SET `terms_version` = :version WHERE `account_id` = :account_id'.($dg?'':' AND `terms_version` < :version'), {
          account_id => $account_id,
          version => $version,
        }, source_name => 'master'),
        $app->db->uuid_short (1),
      ])->then (sub {
        die "UPDATE failed" unless $_[0]->[0]->row_count <= 1;
        my $data = {
          source_operation => 'agree',
          version => $version,
        };
        my $app_obj = $app->bare_param ('source_data');
        $data->{source_data} = json_bytes2perl $app_obj if defined $app_obj;
        return $app->db->insert ('account_log', [{
          log_id => $_[0]->[1]->[0],
          account_id => $account_id,
          operator_account_id => $account_id,
          timestamp => time,
          action => 'agree',
          ua => $app->bare_param ('source_ua') // '',
          ipaddr => $app->bare_param ('source_ipaddr') // '',
          data => Dongry::Type->serialize ('json', $data),
        }]);
      })->then (sub {
        return $app->send_json ({});
      });
    });
  } # /agree

  if (@$path == 2 and $path->[0] eq 'account' and
      ($path->[1] eq 'admin_status' or
       $path->[1] eq 'user_status')) {
    ## /account/user_status - Set the |user_status| of the account
    ## /account/admin_status - Set the |admin_status| of the account
    ##
    ## Parameters
    ##
    ##   |account_id|        - The account's ID.
    ##   |sk_context|, |sk|  - The session.  Either session or account ID is
    ##                         required.
    ##   |admin_status|      - The new |admin_status| value.  A 7-bit
    ##                         positive integer.  Required for /admin_status.
    ##   |user_status|       - The new |user_status| value.  A 7-bit
    ##                         positive integer.  Required for /user_status.
    ##
    ## Returns nothing.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;

    my $key = Dongry::Type->serialize ('text', $path->[1]);
    my $new_status = $app->bare_param ($key)
        or return $app->throw_error (400, reason_phrase => 'Bad |'.$key.'|');

    my $account_id = $app->bare_param ('account_id');
    return Promise->resolve->then (sub {
      if (defined $account_id) {
        return $app->db->select ('account', {
          account_id => $account_id,
        }, source_name => 'master', fields => ['account_id', 'name'])->then (sub {
          my $v = $_[0];
          my $row = $v->first_as_row;
          return $app->throw_error_json ({reason => 'Bad |account_id|'})
              unless defined $row;
          return $row->update ({$key => 0+$new_status}, source_name => 'master');
        });
      } else {
        return $class->resume_session ($app)->then (sub {
          my $session_row = $_[0];
          return $app->throw_error_json ({reason => 'Not a login user'})
              unless defined $session_row;
          $account_id = $session_row->get ('data')->{account_id};
          return $app->throw_error_json ({reason => 'Not a login user'})
              unless defined $account_id;
          return $app->db->update ('account', {
            $key => 0+$new_status,
          }, where => {
            account_id => 0+$account_id,
          })->then (sub {
            my $result = $_[0];
            die "Bad account ID" unless $result->row_count == 1;
          });
        });
      }
    })->then (sub {
      return $app->db->uuid_short (1);
    })->then (sub {
      my $ids = $_[0];
      my $data = {
        source_operation => $path->[1],
      };
      $data->{$path->[1]} = $new_status;
      my $app_obj = $app->bare_param ('source_data');
      $data->{source_data} = json_bytes2perl $app_obj if defined $app_obj;
      return $app->db->insert ('account_log', [{
        log_id => $ids->[0],
        account_id => 0+$account_id,
        operator_account_id => 0+($app->bare_param ('operator_account_id') // $account_id),
        timestamp => time,
        action => $path->[1],
        ua => $app->bare_param ('source_ua') // '',
        ipaddr => $app->bare_param ('source_ipaddr') // '',
        data => Dongry::Type->serialize ('json', $data),
      }]);
    })->then (sub {
      return $app->send_json ({});
    });
  } # /account/*_status

  if (@$path == 1 and $path->[0] eq 'search') {
    ## /search - User search
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $q = $app->text_param ('q');
    my $q_like = Dongry::Type->serialize ('text', '%' . (like $q) . '%');

    # XXX better full-text search
    return (((length $q) ? $app->db->execute ('SELECT account_id,service_name,linked_name,linked_id,linked_key FROM account_link WHERE linked_id like :linked_id or linked_key like :linked_key or linked_name like :linked_name LIMIT :limit', {
      linked_id => $q_like,
      linked_key => $q_like,
      linked_name => $q_like,
      limit => $app->bare_param ('per_page') || 20,
    }, source_name => 'master', table_name => 'account_link')->then (sub {
      return $_[0]->all_as_rows;
    }) : Promise->resolve ([]))->then (sub {
      my $accounts = {};
      for my $row (@{$_[0]}) {
        my $v = {};
        for (qw(id key name)) {
          my $x = $row->get ('linked_' . $_);
          $v->{$_} = $x if length $x;
        }
        my $aid = $row->get ('account_id');
        $accounts->{$aid}->{services}->{$row->get ('service_name')} = $v;
        $accounts->{$aid}->{account_id} = format_id $aid;
      }
      # XXX filter by account.user_status && account.admin_status
      return $app->send_json ({accounts => $accounts});
    }));
  } # /search

  if (@$path == 2 and $path->[0] eq 'log' and $path->[1] eq 'get') {
    ## /log/get - Get account logs
    ##
    ## Parameters
    ##
    ##   |use_sk|            - If true, |sk| is used to specify the account
    ##                         ID of the logs.
    ##   |log_id|            - The log ID of the log.
    ##   |account_id|        - The account ID of the logs.
    ##   |operator_account_id| - The operator account ID of the logs.
    ##   |ipaddr|            - The IP address of the logs.
    ##   |action|            - The action of the logs.
    ##   At least one of these six groups of parameters is required.
    ##
    ##   |sk|, |sk_context|, |sk_max_age|
    ##
    ## Returns
    ##   |items|             - An array of logs.
    ##
    ## Supports paging.
    $app->requires_request_method ({POST => 1});
    $app->requires_api_key;
    my $page = this_page ($app, limit => 50, max_limit => 100);
    my $where = {};
    return Promise->resolve->then (sub {
      for my $key (qw(account_id operator_account_id ipaddr
                      action log_id)) {
        $where->{$key} = $app->bare_param ($key);
        delete $where->{$key} if not defined $where->{$key};
      }
      if ($app->bare_param ('use_sk')) {
        return $app->throw_error
            (400, reason_phrase => 'Both |sk| and |account_id| is specified')
            if defined $app->bare_param ('account_id');
        return $class->resume_session ($app)->then (sub {
          my $session_row = $_[0];
          $where->{account_id} = $session_row->get ('data')->{account_id} # or undef
              if defined $session_row;
          $where->{account_id} = Dongry::Type->serialize ('text', $where->{account_id})
              if defined $where->{account_id};
        });
      }
    })->then (sub {
      return [] if not defined $where->{account_id} and
          $app->bare_param ('use_sk');
      return $app->throw_error (400, reason_phrase => 'No params')
          unless keys %$where;

      $where->{timestamp} = $page->{value} if defined $page->{value};

      return $app->db->select (
        'account_log', $where,
        fields => ['account_id', 'operator_account_id', 'ipaddr',
                   'action', 'log_id', 'ua', 'timestamp', 'data'],
        source_name => 'master',
        offset => $page->{offset}, limit => $page->{limit},
        order => ['timestamp', $page->{order_direction}],
      )->then (sub {
        my $v = $_[0];
        my $items = [map {
          $_->{account_id} .= '';
          $_->{operator_account_id} .= '';
          $_->{log_id} .= "";
          $_->{data} = Dongry::Type->parse ('json', $_->{data});
          $_;
        } $v->all->to_list];
        return $items;
      });
    })->then (sub {
      my $items = $_[0];
      my $next_page = next_page $page, $items, 'timestamp';
      return $app->send_json ({
        items => $items,
        %$next_page,
      });
    });
  } # /log/get

  if (@$path == 1 and $path->[0] eq 'robots.txt') {
    # /robots.txt
    return $app->send_plain_text ("User-agent: *\nDisallow: /");
  }

  return $app->send_error (404);
} # main

sub resume_session ($$;$) {
  my ($class, $app, $tr) = @_;
  my $sk = $app->bare_param ('sk') // '';
  return (length $sk ? ($tr // $app->db)->select ('session', {
    sk => $sk,
    sk_context => $app->bare_param ('sk_context') // '',
    expires => {'>', time},
  }, source_name => 'master', lock => (defined $tr ? 'update' : undef))->then (sub {
    my $session_row = $_[0]->first_as_row;
    return undef unless defined $session_row;

    my $session_data = $session_row->get ('data');
    return undef if not defined $session_data->{session_id}; # sessions before R5.10.3 does not have |session_id|

    my $ma = $app->bare_param ('sk_max_age');
    if ($ma) {
      unless (($session_data->{login_time} || 0) + $ma > time) {
        return undef;
      }
    }
    
    return $session_row;
  }) : Promise->resolve (undef));
} # resume_session

sub write_session_log ($$$$;%) {
  my ($class, $app, $session_row, $now, %args) = @_;
  my $data = {
    ua => $app->bare_param ('source_ua') // '',
    ipaddr => $app->bare_param ('source_ipaddr') // '',
  };
  my $app_obj = $app->bare_param ('source_data');
  $data->{source_data} = json_bytes2perl $app_obj if defined $app_obj;
  if ($args{force} or length $data->{ipaddr} or length $data->{ua} or
      defined $data->{source_data}) {
    my $session_data = $session_row->get ('data');
    return $app->db->insert ('session_recent_log', [{
      sk => $session_row->get ('sk'),
      sk_context => $session_row->get ('sk_context'),
      account_id => 0+($session_data->{account_id} || 0),
      session_id => 0+$session_data->{session_id},
      timestamp => $now,
      expires => $session_row->get ('expires'),
      data => Dongry::Type->serialize ('json', $data),
    }], duplicate => 'replace');
  } else {
    return Promise->resolve;
  }
} # write_session_log

sub delete_old_sessions ($$) {
  my $db = $_[1]->db;
  return $db->delete ('session', {
    expires => {'<', time},
  })->then (sub {
    return $db->delete ('session_recent_log', {
      expires => {'<', time},
    });
  });
} # delete_old_sessions

sub delete_old_login_tokens ($$) {
  my ($class, $app) = @_;
  my $time = time;
  my $email_window = $app->config->get ('login_email_rate_limit_email_window') || 3600;
  my $ip_window = $app->config->get ('login_email_rate_limit_ip_window') || 600;
  my $max_window = $email_window > $ip_window ? $email_window : $ip_window;
  return $app->db->delete ('login_token', {
    created => {'<', $time - $max_window},
    expires => {'<', $time},
  }, source_name => 'master');
} # delete_old_login_tokens

sub load_data ($$$$$$$$$) {
  my ($class, $app, $prefix, $table_name, $id_key, $id2_key, $id2_value, $items, $item_key) = @_;

  my $id_to_json = {};
  my @id = map {
    $id_to_json->{$_->{$id_key}} = $_;
    Dongry::Type->serialize ('text', $_->{$id_key});
  } grep { defined $_->{$id_key} } @$items;
  return Promise->resolve ($items) unless @id;

  my @field = map { Dongry::Type->serialize ('text', $_) } $app->text_param_list ('with_'.$prefix.'data')->to_list;
  return Promise->resolve ($items) unless @field;

  return $app->db->select ($table_name, {
    $id_key => {-in => \@id},
    (defined $id2_key ? ($id2_key => Dongry::Type->serialize ('text', $id2_value)) : ()),
    key => {-in => \@field},
  }, source_name => 'master')->then (sub {
    for (@{$_[0]->all}) {
      my $json = $id_to_json->{$_->{$id_key}};
      $json->{$item_key}->{$_->{key}} = Dongry::Type->parse ('text', $_->{value})
          if defined $_->{value} and length $_->{value};
    }
    return $items;
  });
} # load_data

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
