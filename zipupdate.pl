#!/usr/bin/perl

use strict;
use warnings;

use Archive::Zip qw(:ERROR_CODES);
use English;
use IPC::Open2;
use Getopt::Long qw(:config bundling);
use Pod::Usage;

our $VERBOSE = 0;

# In a list of zip archives, for each contained file whose name matches a
# pattern, filter the file content through an external command and write the
# result back to the archive in-place.
#
# Parameters:
#     \@files Array of zip archive file names
#     $inner_re Regular expression to match inner file names
#     $command External command to filter matching files
# Returns: true on success, false if any command failed
#
sub update_archives($$$) {
	my ($files, $inner_re, $command) = @_;
	my $error_count = 0;
	foreach my $filename (@$files) {
		my $zip = Archive::Zip->new();
		if ($zip->read($filename) != AZ_OK) {
			++$error_count;
			next;
		}
		my $changed = 0;
		foreach my $member ($zip->membersMatching($inner_re)) {
			next if $member->isDirectory();
			my $member_filename = $member->fileName();
			my $contents = $zip->contents($member);
			my $filtered = filter($contents, $command);
			if (defined($filtered)) {
				if ($filtered eq $contents) {
					info("Unchanged $filename: $member_filename\n");
				} else {
					info("Updating $filename: $member_filename\n");
					$zip->contents($member, $filtered);
					$changed = 1;
				}
			} else {
				error("Not updating $filename: $member_filename\n");
				++$error_count;
			}
		}
		$zip->overwrite() if $changed;
	}
	return $error_count == 0;
}

# Filter a scalar variable through a command. The command is interpreted by a
# shell and may contain pipes etc itself.
#
# Parameters:
#     $content Content to filter
#     $command Filter command
# Returns: Filtered result, or undef if the command did not exit cleanly with
#     status 0
#
sub filter($$) {
	my ($content, $command) = @_;
	my ($read, $write, $result);
	# Need to fork for open2(), because both read() and print() can block.
	# See also the documentation for IPC::Open2
	my $cmd_pid = open2($read, $write, $command);
	my $pid = fork();
	die("Can't fork()") if not defined($pid);
	if ($pid == 0) {
		# I'm the child
		close($read);
		print($write $content);
		close($write);
		exit(0);
	} else {
		# I'm the parent
		close($write);
		local $INPUT_RECORD_SEPARATOR; # slurp mode
		$result = <$read>;
		close($read);
		waitpid($pid, 0);
	}
	waitpid($cmd_pid, 0);
	return $result if $CHILD_ERROR == 0;
	return undef;
}

sub info {
	print(@_) if $VERBOSE;
}

sub error {
	print(STDERR @_);
}

# Process command line arguments
my $inner_re = "";
my $command;
my %options = (
	'help|h' => sub { pod2usage(-verbose => 2, -exitval => 0) },
	'verbose|v' => \$VERBOSE,
	'match|m=s' => \$inner_re,
	'command|c=s' => \$command,
);
GetOptions(%options) or pod2usage(-verbose => 0, -exitval => 2);
my @files = @ARGV;
unless (defined($command)) {
	pod2usage(-verbose => 0, -exitval => 2);
}
my $success = update_archives(\@files, $inner_re, $command);
exit($success ? 0 : 1);

__END__

=pod

=head1 NAME

zipupdate - Update .zip archives in-place

=head1 SYNOPSIS

zipupdate.pl [--match "\.xml"] --command <filter> *.zip

=head1 DESCRIPTION

This program acts on one or more .zip archives. For each contained file whose
name matches a given pattern, the file content is filtered by an external
command and written back to the .zip archive.

=head1 ARGUMENTS

=over 4

=item B<-h, --help>

Print program help and exit

=item B<-v, --verbose>

Print output about every performed operation.

=item B<-c, --command> filter-command

Command line with arguments to filter files through. The command is expected to
accept input on stdin and write output to stdout. The command is interpreted by
a shell and may contain pipes etc.

=item B<-m, --match> regex

Optional argument: A regular expression that describes which inner files of the
.zip archives to modify. It is matched against full file names and paths of the
contained files. The forward slash "/" is used as directory delimiter. If not
given, all files are matched.

=back

=head1 EXAMPLES

=head2 How to update .zip files full of .xml files

Assume you have a number zip archives that contain a tree of XML files and you
want to make systematic changes in all of them.

I<xmlstarlet> is a command line tool to alter XML files and is well suited to
add attributes, rename elements etc based on XPath expressions.

=over 4

=item B<Adding an attribute to a certain element>

  find . -name "*.zip" -print0 | xargs -0 zipupdate.pl \
    --match "directoryname/.*\.xml" --command \
    "xmlstarlet edit -P -S --insert //MatchingElement --type attr --name newattribute --value value"

=item B<Removing an attribute from all nodes>

  find . -name "*.zip" -print0 | xargs -0 zipupdate.pl \
    --match "\.xml" --command "xmlstarlet edit -P -S --delete //@version"

=item B<Adding a new child element>

  find . -name "*.zip" -print0 | xargs -0 zipupdate.pl \
    --match "\.xml" --command \
    "xmlstarlet edit -P -S --subnode /RootElement/MainElement --type elem --name DetailElement --value ''"

=back

=head2 Encoding conversion

=over 4

=item B<Converting XML files>

The I<command> is interpreted by a shell and you can use pipes:

  find . -name "*.zip" -print0 | xargs -0 zipupdate.pl \
    --match "\.xml" --command \
    'recode iso-8859-1..utf8 | sed -e "s/\(<?xml version=\"1.0\" encoding=\"\)iso-8859-1\(\"?>\)/\1utf-8\2/"'

=back

=head1 SEE ALSO

=over 4

=item I<http://xmlstar.sourceforge.net/>

XMLStarlet Command Line XML Toolkit

=back
