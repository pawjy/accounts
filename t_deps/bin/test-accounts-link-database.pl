use strict;
use warnings;
use Test::More;
use Path::Tiny;
use Promise;
use Dongry::Database;
use Dongry::Type;
use Dongry::Type::JSONPS;
use JSON::PS;

# Run in the built Accounts image with a new, empty disposable database.
# Arguments: Login.pm account.sql host port rabbit_accounts_link_test_SUFFIX
my ($source_path, $schema_path, $host, $port, $database_name) = @ARGV;
die "Expected source, schema, host, port and a disposable database name\n"
    unless @ARGV == 5 && $host =~ /\A[a-zA-Z0-9.-]+\z/ && $port =~ /\A[0-9]+\z/ &&
           $database_name =~ /\Arabbit_accounts_link_test_[a-z0-9]+\z/;
alarm 120;
my $source = path ($source_path)->slurp;
my ($helper) = $source =~ /(sub _link_add_transaction \(\$\$\$\).*?\n\} # _link_add_transaction)/s;
my ($body) = $source =~ /return _link_add_transaction \(\$app->db, sub \{(.*?)\n        \}, 2\);/s;
die 'Missing Accounts source' unless defined $helper and defined $body;
eval $helper;
die $@ if $@;
sub wait_result { Promise->resolve ($_[0])->to_cv->recv }
sub database {
  return Dongry::Database->new (
    sources => {master => {
      dsn => "dbi:mysql:dbname=$database_name;host=$host;port=$port;user=root",
      anyevent => 1, writable => 1,
    }}, master_only => 1, onerror => sub {},
  );
}
{
  package LinkFixtureApp;
  sub bare_param { undef }
  package LinkObservedTransaction;
  sub delete {
    my $self = shift;
    return $self->{tr}->delete (@_)->then (sub {
      return $self->{after_delete}->() if $self->{after_delete};
      return $_[0];
    });
  }
  sub insert { my $self = shift; return $self->{tr}->insert (@_) }
}
my $app = bless {}, 'LinkFixtureApp';
sub link_work {
  my ($account_id, $link_id, $log_id, $replace, $linked_id, $linked_key) = @_;
  my $server = {name => 'stripe'};
  my $time = 1;
  my $code = eval 'sub {' . $body . '}';
  die $@ if $@;
  return $code;
}
my $db = database;
die "The disposable database must be empty\n"
    if wait_result ($db->execute ('SHOW TABLES'))->row_count;
my $schema = path ($schema_path)->slurp;
for my $name (qw(account_link account_log)) {
  my ($table) = $schema =~ /(CREATE TABLE IF NOT EXISTS `?\Q$name\E`? \([\s\S]*?ENGINE=InnoDB;)/;
  die "Missing table $name" unless defined $table;
  wait_result ($db->execute ($table));
}
while ($schema =~ /(alter table `account_link`\s[\s\S]*?;)/g) {
  wait_result ($db->execute ($1));
}
sub reset_rows {
  wait_result ($db->execute ('TRUNCATE TABLE account_link'));
  wait_result ($db->execute ('TRUNCATE TABLE account_log'));
}
sub row_count {
  my ($table, $account_ids) = @_;
  return wait_result ($db->select ($table, {account_id => {-in => $account_ids}}))->row_count;
}
sub paired_replacements {
  my ($same_account, $retries) = @_;
  my ($release, $deleted);
  $deleted = 0;
  my $barrier = Promise->new (sub { ($release) = @_ });
  my @attempts;
  my @connections;
  my $result = wait_result (Promise->all ([map {
    my $slot = $_;
    my $account_id = $same_account ? 100 : 101 + $slot;
    my $connection = database;
    push @connections, $connection;
    my $code = link_work ($account_id, 501+$slot, 601+$slot, 1, undef, 'customer-'.$slot);
    $attempts[$slot] = 0;
    _link_add_transaction ($connection, sub {
      my $tr = $_[0];
      my $first = ++$attempts[$slot] == 1;
      return $code->(bless {tr => $tr, after_delete => ($first ? sub {
        $release->() if ++$deleted == 2;
        return $barrier;
      } : undef)}, 'LinkObservedTransaction');
    }, $retries)->then (sub { return 'ok' }, sub {
      return UNIVERSAL::isa ($_[0], 'Dongry::Database::Executed') &&
             $_[0]->error_text =~ /\(Error code 1213\)\z/ ? 'deadlock' : 'other error';
    });
  } (0, 1)]));
  wait_result ($_ ->disconnect) for @connections;
  return ($result, \@attempts);
}

reset_rows ();
my ($result, $attempts) = paired_replacements (0, 0);
is_deeply [sort @$result], ['deadlock', 'ok'], 'unchanged SQL without recovery reproduces the deadlock';
is row_count ('account_link', [101, 102]), 1, 'failed transaction saves no link';
is row_count ('account_log', [101, 102]), 1, 'failed transaction saves no log';
reset_rows ();
($result, $attempts) = paired_replacements (0, 2);
is_deeply $result, ['ok', 'ok'], 'distinct accounts both complete with recovery';
is_deeply [sort @$attempts], [1, 2], 'only the rolled-back transaction is repeated';
is row_count ('account_link', [101, 102]), 2, 'both links are saved';
is row_count ('account_log', [101, 102]), 2, 'each successful request records exactly one log';
reset_rows ();
($result, $attempts) = paired_replacements (1, 2);
is_deeply $result, ['ok', 'ok'], 'same-account replacements both complete';
is row_count ('account_link', [100]), 1, 'same-account replacement retains serial whole-replacement semantics';
is row_count ('account_log', [100]), 2, 'two successful replacements record two logs';
my $last = wait_result ($db->select ('account_link', {account_id => 100}))->first;
ok $last->{linked_key} eq 'customer-0' || $last->{linked_key} eq 'customer-1', 'the final link is one complete submitted value';
reset_rows ();
for my $slot (0, 1) {
  wait_result (_link_add_transaction ($db, link_work (200, 701+$slot, 801+$slot, 0, undef, 'add-'.$slot), 2));
}
is row_count ('account_link', [200]), 2, 'normal addition retains separate links';
wait_result (_link_add_transaction ($db, link_work (200, 703, 803, 1, undef, 'replacement'), 2));
is row_count ('account_link', [200]), 1, 'replace removes all previous service links';
is row_count ('account_log', [200]), 3, 'additions and replacement each keep their original log';
my $error;
_link_add_transaction ($db, link_work (200, 704, 803, 1, undef, 'must-rollback'), 2)->catch (sub {
  $error = $_[0];
})->to_cv->recv;
like $error->error_text, qr/\(Error code 1062\)\z/, 'a duplicate log error is not retried';
my $links = wait_result ($db->select ('account_link', {account_id => 200}))->all;
is $links->length, 1, 'failed log insertion rolls the replacement back';
is $links->[0]->{linked_key}, 'replacement', 'the old link survives the complete rollback';
is row_count ('account_log', [200]), 3, 'failed request leaves no extra log';
wait_result (_link_add_transaction ($db, link_work (200, 705, 805, 0, undef, 'after-error'), 2));
is row_count ('account_link', [200]), 2, 'the connection is usable after rollback';
my $isolation = wait_result ($db->execute ('SELECT @@tx_isolation AS value'))->first->{value};
is $isolation, 'REPEATABLE-READ', 'the existing transaction isolation is unchanged';
wait_result ($db->disconnect);
done_testing;
