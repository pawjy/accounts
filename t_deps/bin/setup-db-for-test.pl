use strict;
use warnings;
use Path::Tiny;

my $root_path = path (__FILE__)->parent->parent->parent;
my $sql_path = $root_path->child ('db/account.sql');

my $dsn = shift or die "Usage: $0 dsn";
$dsn =~ s/^dbi:mysql://i;

my $db = {};
for (split /;/, $dsn) {
  if (/^([^=]+)=(.+)$/) {
    $db->{$1} = $2;
  }
}

my @cmd = 'mysql';
push @cmd, '-u' . $db->{user} if defined $db->{user};
push @cmd, '-p' . $db->{password} if defined $db->{password};
push @cmd, '-h' . $db->{host} if defined $db->{host};
push @cmd, '-P' . $db->{port} if defined $db->{port};
push @cmd, '-S' . $db->{mysql_socket} if defined $db->{mysql_socket};
push @cmd, $db->{dbname} // $db->{database};

my $cmd = join ' ', map { quotemeta $_ } @cmd;
(system "echo 'create database account_test' | $cmd") == 0 or die $?;
(system "$cmd < $sql_path") == 0 or die $?;
