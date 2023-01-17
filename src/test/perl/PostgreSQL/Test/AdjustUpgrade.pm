
# Copyright (c) 2023, PostgreSQL Global Development Group

=pod

=head1 NAME

PostgreSQL::Test::AdjustUpgrade - helper module for cross-version upgrade tests

=head1 SYNOPSIS

  use PostgreSQL::Test::AdjustUpgrade;

  # Build commands to adjust contents of old-version database before dumping
  $statements = adjust_database_contents($old_version, %dbnames);

  # Adjust contents of old pg_dumpall output file to match newer version
  $dump = adjust_old_dumpfile($old_version, $dump);

  # Adjust contents of new pg_dumpall output file to match older version
  $dump = adjust_new_dumpfile($old_version, $dump);

=head1 DESCRIPTION

C<PostgreSQL::Test::AdjustUpgrade> encapsulates various hacks needed to
compare the results of cross-version upgrade tests.

=cut

package PostgreSQL::Test::AdjustUpgrade;

use strict;
use warnings;

use Exporter 'import';
use PostgreSQL::Version;

our @EXPORT = qw(
  adjust_database_contents
  adjust_old_dumpfile
  adjust_new_dumpfile
);

=pod

=head1 ROUTINES

=over

=item $statements = adjust_database_contents($old_version, %dbnames)

Generate SQL commands to perform any changes to an old-version installation
that are needed before we can pg_upgrade it into the current PostgreSQL
version.

Typically this involves dropping or adjusting no-longer-supported objects.

Arguments:

=over

=item C<old_version>: Branch we are upgrading from, represented as a
PostgreSQL::Version object.

=item C<dbnames>: Hash of database names present in the old installation.

=back

Returns a reference to a hash, wherein the keys are database names and the
values are arrayrefs to lists of statements to be run in those databases.

=cut

sub adjust_database_contents
{
	my ($old_version, %dbnames) = @_;
	my $result = {};

	# remove dbs of modules known to cause pg_upgrade to fail
	# anything not builtin and incompatible should clean up its own db
	foreach my $bad_module ('test_ddl_deparse', 'tsearch2')
	{
		if ($dbnames{"contrib_regression_$bad_module"})
		{
			_add_st($result, 'postgres',
				"drop database contrib_regression_$bad_module");
			delete($dbnames{"contrib_regression_$bad_module"});
		}
	}

	# avoid version number issues with test_ext7
	if ($dbnames{contrib_regression_test_extensions})
	{
		_add_st(
			$result,
			'contrib_regression_test_extensions',
			'drop extension if exists test_ext7');
	}

	# get rid of dblink's dependencies on regress.so
	my $regrdb =
	  $old_version le '9.4'
	  ? 'contrib_regression'
	  : 'contrib_regression_dblink';

	if ($dbnames{$regrdb})
	{
		_add_st(
			$result, $regrdb,
			'drop function if exists public.putenv(text)',
			'drop function if exists public.wait_pid(integer)');
	}

	return $result;
}

# Internal subroutine to add statement(s) to the list for the given db.
sub _add_st
{
	my ($result, $db, @st) = @_;

	$result->{$db} ||= [];
	push(@{ $result->{$db} }, @st);
}

=pod

=item adjust_old_dumpfile($old_version, $dump)

Edit a dump output file, taken from the adjusted old-version installation
by current-version C<pg_dumpall -s>, so that it will match the results of
C<pg_dumpall -s> on the pg_upgrade'd installation.

Typically this involves coping with cosmetic differences in the output
of backend subroutines used by pg_dump.

Arguments:

=over

=item C<old_version>: Branch we are upgrading from, represented as a
PostgreSQL::Version object.

=item C<dump>: Contents of dump file

=back

Returns the modified dump text.

=cut

sub adjust_old_dumpfile
{
	my ($old_version, $dump) = @_;

	# use Unix newlines
	$dump =~ s/\r\n/\n/g;

	# Version comments will certainly not match.
	$dump =~ s/^-- Dumped from database version.*\n//mg;

	if ($old_version lt '9.3')
	{
		# CREATE VIEW/RULE statements were not pretty-printed before 9.3.
		# To cope, reduce all whitespace sequences within them to one space.
		# This must be done on both old and new dumps.
		$dump = _mash_view_whitespace($dump);

		# _mash_view_whitespace doesn't handle multi-command rules;
		# rather than trying to fix that, just hack the exceptions manually.

		my $prefix =
		  "CREATE RULE rtest_sys_del AS ON DELETE TO public.rtest_system DO (DELETE FROM public.rtest_interface WHERE (rtest_interface.sysname = old.sysname);";
		my $line2 = " DELETE FROM public.rtest_admin";
		my $line3 = " WHERE (rtest_admin.sysname = old.sysname);";
		$dump =~
		  s/(?<=\Q$prefix\E)\Q$line2$line3\E \);/\n$line2\n $line3\n);/mg;

		$prefix =
		  "CREATE RULE rtest_sys_upd AS ON UPDATE TO public.rtest_system DO (UPDATE public.rtest_interface SET sysname = new.sysname WHERE (rtest_interface.sysname = old.sysname);";
		$line2 = " UPDATE public.rtest_admin SET sysname = new.sysname";
		$line3 = " WHERE (rtest_admin.sysname = old.sysname);";
		$dump =~
		  s/(?<=\Q$prefix\E)\Q$line2$line3\E \);/\n$line2\n $line3\n);/mg;

		# and there's one place where pre-9.3 uses a different table alias
		$dump =~ s {^(CREATE\sRULE\srule_and_refint_t3_ins\sAS\s
			 ON\sINSERT\sTO\spublic\.rule_and_refint_t3\s
			 WHERE\s\(EXISTS\s\(SELECT\s1\sFROM\spublic\.rule_and_refint_t3)\s
			 (WHERE\s\(\(\(rule_and_refint_t3)
			 (\.id3a\s=\snew\.id3a\)\sAND\s\(rule_and_refint_t3)
			 (\.id3b\s=\snew\.id3b\)\)\sAND\s\(rule_and_refint_t3)}
		{$1 rule_and_refint_t3_1 $2_1$3_1$4_1}mx;

		# Also fix old use of NATURAL JOIN syntax
		$dump =~ s {NATURAL JOIN public\.credit_card r}
			{JOIN public.credit_card r USING (cid)}mg;
		$dump =~ s {NATURAL JOIN public\.credit_usage r}
			{JOIN public.credit_usage r USING (cid)}mg;
	}

	# Suppress blank lines, as some places in pg_dump emit more or fewer.
	$dump =~ s/\n\n+/\n/g;

	return $dump;
}

# Internal subroutine to mangle whitespace within view/rule commands.
# Any consecutive sequence of whitespace is reduced to one space.
sub _mash_view_whitespace
{
	my ($dump) = @_;

	foreach my $leader ('CREATE VIEW', 'CREATE RULE')
	{
		my @splitchunks = split $leader, $dump;

		$dump = shift(@splitchunks);
		foreach my $chunk (@splitchunks)
		{
			my @thischunks = split /;/, $chunk, 2;
			my $stmt = shift(@thischunks);

			# now $stmt is just the body of the CREATE VIEW/RULE
			$stmt =~ s/\s+/ /sg;
			# we also need to smash these forms for sub-selects and rules
			$stmt =~ s/\( SELECT/(SELECT/g;
			$stmt =~ s/\( INSERT/(INSERT/g;
			$stmt =~ s/\( UPDATE/(UPDATE/g;
			$stmt =~ s/\( DELETE/(DELETE/g;

			$dump .= $leader . $stmt . ';' . $thischunks[0];
		}
	}
	return $dump;
}

=pod

=item adjust_new_dumpfile($old_version, $dump)

Edit a dump output file, taken from the pg_upgrade'd installation
by current-version C<pg_dumpall -s>, so that it will match the old
dump output file as adjusted by C<adjust_old_dumpfile>.

Typically this involves deleting data not present in the old installation.

Arguments:

=over

=item C<old_version>: Branch we are upgrading from, represented as a
PostgreSQL::Version object.

=item C<dump>: Contents of dump file

=back

Returns the modified dump text.

=cut

sub adjust_new_dumpfile
{
	my ($old_version, $dump) = @_;

	# use Unix newlines
	$dump =~ s/\r\n/\n/g;

	# Version comments will certainly not match.
	$dump =~ s/^-- Dumped from database version.*\n//mg;

	if ($old_version lt '9.3')
	{
		# CREATE VIEW/RULE statements were not pretty-printed before 9.3.
		# To cope, reduce all whitespace sequences within them to one space.
		# This must be done on both old and new dumps.
		$dump = _mash_view_whitespace($dump);
	}

	# Suppress blank lines, as some places in pg_dump emit more or fewer.
	$dump =~ s/\n\n+/\n/g;

	return $dump;
}

=pod

=back

=cut

1;
