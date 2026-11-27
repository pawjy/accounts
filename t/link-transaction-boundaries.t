use strict;
use FindBin;
use lib glob "$FindBin::Bin/../modules/*/lib";
use lib glob "$FindBin::Bin/../t_deps/modules/*/lib";
use lib "$FindBin::Bin/../lib";
use warnings;
use Test::More;
use Promise;
use Dongry::Database;
use Path::Tiny;

my $source = path (@ARGV ? shift : "$FindBin::Bin/../lib/Accounts/Web/Login.pm")->slurp;
my ($helper) = $source =~ /(sub _link_add_transaction \(\$\$\$\).*?\n\} # _link_add_transaction)/s;
die 'Missing transaction helper' unless defined $helper;
eval $helper;
die $@ if $@;
sub sql_error {
  return bless {error_text => "Synthetic SQL failure (Error code $_[0])"},
      'Dongry::Database::Executed::NotAvailable';
}
{
  package LinkTestDB;
  sub transaction {
    my $db = shift;
    push @{$db->{events}}, 'begin';
    return Promise->reject ($db->{begin_error}) if $db->{begin_error};
    return Promise->resolve (bless {db => $db}, 'LinkTestTransaction');
  }
  package LinkTestTransaction;
  sub commit {
    my $db = $_[0]->{db};
    push @{$db->{events}}, 'commit';
    return $db->{commit_error} ? Promise->reject ($db->{commit_error}) : Promise->resolve ();
  }
  sub rollback {
    my $db = $_[0]->{db};
    push @{$db->{events}}, 'rollback';
    return $db->{rollback_error} ? Promise->reject ($db->{rollback_error}) : Promise->resolve ();
  }
}
sub run_case {
  my ($errors, %options) = @_;
  my $db = bless {events => [], %options}, 'LinkTestDB';
  my $calls = 0;
  my $failure;
  _link_add_transaction ($db, sub {
    push @{$db->{events}}, 'work';
    my $error = $errors->[$calls++];
    return Promise->reject ($error) if defined $error && $options{async_error};
    die $error if defined $error;
    return Promise->resolve ();
  }, 2)->then (sub { return 1 }, sub { $failure = $_[0]; return 0 })->to_cv->recv;
  return ($db->{events}, $failure, $calls);
}
my ($events, $error, $calls) = run_case ([]);
is_deeply $events, [qw(begin work commit)], 'success commits once';
is $error, undef, 'success has no error';
($events, $error, $calls) = run_case ([sql_error (1213)]);
is_deeply $events, [qw(begin work rollback begin work commit)], 'deadlock is rolled back before a fresh transaction';
is $error, undef, 'one deadlock is recovered';
($events, $error, $calls) = run_case ([sql_error (1213)], async_error => 1);
is_deeply $events, [qw(begin work rollback begin work commit)], 'asynchronous SQL rejection uses the same recovery';
is $error, undef, 'asynchronous deadlock is recovered';
my $deadlock = sql_error (1213);
($events, $error, $calls) = run_case ([$deadlock, $deadlock, $deadlock]);
is $calls, 3, 'recovery has at most three total attempts';
is $error, $deadlock, 'exhaustion returns the original database error';
is_deeply $events, [(qw(begin work rollback)) x 3], 'every failed attempt is rolled back';
for my $code (1205, 1062, 2006, 2013) {
  my $failure = sql_error ($code);
  ($events, $error, $calls) = run_case ([$failure]);
  is_deeply $events, [qw(begin work rollback)], "error $code is not retried";
  is $error, $failure, "error $code is preserved";
}
for my $failure ('HTTP 500 (Error code 1213)', bless ({}, 'LinkOtherFailure')) {
  ($events, $error, $calls) = run_case ([$failure]);
  is_deeply $events, [qw(begin work rollback)], 'non-database exception is not retried';
}
($events, $error, $calls) = run_case ([], commit_error => $deadlock);
is_deeply $events, [qw(begin work commit)], 'commit failure is never replayed';
is $error, $deadlock, 'commit failure is propagated';
($events, $error, $calls) = run_case ([$deadlock], rollback_error => 'rollback failed');
is_deeply $events, [qw(begin work rollback)], 'rollback failure prevents another attempt';
like $error, qr/rollback failed/, 'rollback failure is propagated';
($events, $error, $calls) = run_case ([], begin_error => $deadlock);
is_deeply $events, ['begin'], 'begin failure is not replayed';
is $error, $deadlock, 'begin failure is propagated';
done_testing;
