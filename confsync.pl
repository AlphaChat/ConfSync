use strict;
use warnings;
use diagnostics;

use JSON;
use IPC::Open3;
use POSIX qw/:sys_wait_h/;

our $config_file;

sub BEGIN
{
	use Cwd qw/chdir/;

	our $VERSION = '2.0';
	printf " ConfSync version %s starting up...", $VERSION;

	unless (exists $ENV{'GIT_WORK_TREE'})
	{
		printf "\n Error: The GIT_WORK_TREE environment variable is missing!\n";
		exit 1;
	}
	unless (defined $ENV{'GIT_WORK_TREE'} && -d $ENV{'GIT_WORK_TREE'})
	{
		printf "\n Error: GIT_WORK_TREE is not a directory!\n";
		exit 1;
	}

	chdir $ENV{'GIT_WORK_TREE'} or die $!;

	$config_file = 'confsync.cfg';

	unless (-f $config_file)
	{
		printf "\n Error: The configuration file is missing!\n";
		exit 1;
	}

	printf "\n\n";
}

my $resyncing_all = 0;
my $command_errors = 0;
my $command_errors_saved = 0;

my $sync = +{};
my $types = +{};
my $config = +{};
my $servers = +{};
my $defaults = +{};

# Determine if an element is in an array
sub in_array
{
	my $needle = shift;
	return grep { $_ eq $needle } @_;
}

# Determine if a server is disabled
sub server_is_disabled
{
	my $name = shift;
	return exists $servers->{$name}->{'disabled'};
}

# Determine if a server exists
sub server_exists
{
	my $name = shift;
	return exists $servers->{$name};
}

# Determine if a server is a type
sub server_is_type
{
	my ($name, $type) = @_;
	return ($servers->{$name}->{'type'} eq $type);
}

# Get a list of configured types
sub get_configured_types
{
	my @types = ();
	foreach my $server (sort values %{$servers})
	{
		next if (in_array $server->{'type'}, @types);
		push @types, $server->{'type'};
	}
	return @types;
}

# Given a type, return all servers in that type
sub get_servers_for_type
{
	my ($type) = @_;
	my @servers = ();
	foreach my $name (sort keys %{$servers})
	{
		next unless ($servers->{$name}->{'type'} eq $type);
		push @servers, $name;
	}
	return @servers;
}

# Get value given a key, useful for when you have defaults set
sub get_value_for_key
{
	my ($name, $key) = @_;

	if (exists $servers->{$name}->{$key})
	{
		return $servers->{$name}->{$key};
	}
	if (exists $types->{$servers->{$name}->{'type'}}->{$key})
	{
		return $types->{$servers->{$name}->{'type'}}->{$key};
	}
	if (exists $defaults->{$key})
	{
		return $defaults->{$key};
	}

	return undef;
}

# Boil the files down to per-type and per-server directories, ignoring duplicates
sub add_server_sync
{
	my ($type, $name, $which_changed) = @_;

	$sync->{$type} = +{} unless (exists $sync->{$type});
	$sync->{$type}->{$name} = +{} unless (exists $sync->{$type}->{$name});

	$sync->{$type}->{$name}->{'global'} = 1 unless ($which_changed == 1);
	$sync->{$type}->{$name}->{'local'} = 1 unless ($which_changed == 0);
}

# Determine what servers need to be synced, given a list of modified files
sub server_process_filepath
{
	my ($file) = @_;

	if (my ($type, $name, $path) = ($file =~ m/^(.+?)\/(.+?)\/(.+)/))
	{
		unless ($name eq 'global')
		{
			unless (server_exists $name)
			{
				printf "   Modified: %s (belongs to an unknown server - skipping)\n", $file;
				return;
			}
			unless (server_is_type $name, $type)
			{
				printf "   Modified: %s (server %s is not of type %s - skipping)\n", $file, $name, $type;
				return;
			}

			printf "   Modified: %s/%s/%s (local)\n", $type, $name, $path;
			add_server_sync $type, $name, 1;
		}
		else
		{
			foreach $name (get_servers_for_type $type)
			{
				if (-e sprintf('%s/%s/%s', $type, $name, $path))
				{
					printf "   Modified: %s/%s/%s (global) -- skipping due to local\n", $type, $name, $path;
					return;
				}

				printf "   Modified: %s/%s/%s (global)\n", $type, $name, $path;
				add_server_sync $type, $name, 0;
			}
		}
	}
	else
	{
		printf "     Modified: %s -- skipping (cannot handle)\n", $file;
	}
}

# Execute a program cleanly and watch for any output
sub better_exec
{
	my ($cmd_pretty_name, @command_args) = @_;

	printf "     Executing %s\n", join(' ', @command_args);

	my ($child_in, $child_out) = (undef, undef);

	open($child_in, '<', '/dev/null') // die $!;
	my $pid = open3($child_in, $child_out, $child_out, @command_args);

	while (<$child_out>)
	{
		s/^\s+|\s+$//g;
		next unless $_;
		printf "     %s: %s\n", $cmd_pretty_name, $_;
	}

	close $child_in;
	close $child_out;
	waitpid $pid, 0;

	if (WIFEXITED($?) && (my $status = WEXITSTATUS($?)) != 0)
	{
		printf "     %s exited with status %d\n", $cmd_pretty_name, $status;
		$command_errors++;
	}
	if (WIFSIGNALED($?) && (my $signal = WTERMSIG($?)) != 0)
	{
		printf "     %s terminated due to signal %d\n", $cmd_pretty_name, $signal;
		$command_errors++;
	}
}

# Do rsync operation
sub do_rsync
{
	my ($name, $dir) = @_;

	my $user = get_value_for_key($name, 'user') // return;
	my $host = get_value_for_key($name, 'host') // return;
	my $confdir = get_value_for_key($name, 'confdir') // return;

	my @command_args =
	(
		'/usr/bin/rsync', '-avxz', '-e', '/usr/bin/ssh',
		$dir, sprintf('%s@%s:%s', $user, $host, $confdir)
	);

	better_exec 'rsync', @command_args;
}

# Run a command on a server
sub do_commands
{
	my ($name, @commands) = @_;

	my $user = get_value_for_key($name, 'user') // return;
	my $host = get_value_for_key($name, 'host') // return;

	foreach my $command (@commands)
	{
		my @command_args =
		(
			'/usr/bin/ssh',
			sprintf('%s@%s', $user, $host),
			$command
		);

		better_exec 'ssh', @command_args;
	}
}

# Parse configuration
printf "   Parsing configuration... ";

{
	local $/;

	open(CONFIG, '<', $config_file) // die $!;
	eval { $config = decode_json(<CONFIG>) } or die $!;
	close(CONFIG);
}

foreach my $required_sect (qw/defaults types servers/)
{
	unless (exists $config->{$required_sect})
	{
		printf "Error: Configuration file is missing required section %s\n", $required_sect;
		exit 1;
	}
}

$types = $config->{'types'};
$servers = $config->{'servers'};
$defaults = $config->{'defaults'};

foreach my $server (keys %{$servers})
{
	# This has to be defined on a per-server basis
	unless (exists $servers->{$server}->{'type'})
	{
		printf "Error: Server '%s' is missing required config option 'type'\n", $server;
		exit 1;
	}

	# If there is no host given, use the server name as host
	# This allows putting host/address in ssh_config(5)
	unless (exists $servers->{$server}->{'host'})
	{
		$servers->{$server}->{'host'} = $server;
	}

	# These can be defined on a per-server basis, or provided by global or type defaults
	foreach my $val (qw/user confdir/)
	{
		next if (get_value_for_key $server, $val);
		printf "Error: Server '%s' is missing required config option '%s'\n", $server, $val;
		exit 1;
	}
}

printf "done\n";

# Determine what files have changed since we last operated and which servers we need to update because of it
my @files = +();
while (my $file = <STDIN>)
{
	$file =~ s/\s$//g;

	push @files, $file;

	if ($file eq $config_file)
	{
		$resyncing_all = 1;
		printf "   Configuration file changed -- resyncing all enabled servers\n\n";
		foreach my $type (get_configured_types())
		{
			foreach my $server (get_servers_for_type $type)
			{
				add_server_sync $type, $server, 2;
			}
		}
		last;
	}
}
unless ($resyncing_all)
{
	printf "\n";

	foreach my $file (@files)
	{
		server_process_filepath $file;
	}
}

# If there are no servers to sync, exit now
unless (scalar keys %{$sync})
{
	printf "   No work to do! Exiting.\n";
	exit 0;
}

# Now we know which servers need syncing and whether they only need local or global files or both updated
foreach my $type (sort keys %{$sync})
{
	foreach my $name (sort keys %{$sync->{$type}})
	{
		next if (server_is_disabled $name);

		my $sourcedir = '';

		printf "\n";
		printf "   Beginning sync for %s (%s) ...\n", $name, $type;

		$command_errors_saved = $command_errors;

		if (exists $sync->{$type}->{$name}->{'global'})
		{
			$sourcedir = sprintf('%s/global/', $type);
			do_rsync($name, $sourcedir) if (-d $sourcedir);
		}
		if (exists $sync->{$type}->{$name}->{'local'})
		{
			$sourcedir = sprintf('%s/%s/', $type, $name);
			do_rsync($name, $sourcedir) if (-d $sourcedir);
		}

		if ($command_errors == $command_errors_saved)
		{
			printf "   File synchronisation successful\n";
		}
		else
		{
			printf "   File synchronisation failed\n";
		}
	}
}

# Now execute any post-synchronisation commands
foreach my $type (sort keys %{$sync})
{
	foreach my $name (sort keys %{$sync->{$type}})
	{
		next if (server_is_disabled $name);

		my $postsync_cmds = get_value_for_key($name, 'postsync_cmds') or next;

		next unless (ref $postsync_cmds eq 'ARRAY');

		printf "\n";
		printf "   Executing post-synchronisation commands for %s (%s) ...\n", $name, $type;

		$command_errors_saved = $command_errors;

		do_commands($name, @{$postsync_cmds});

		if ($command_errors == $command_errors_saved)
		{
			printf "   Post-synchronisation commands successful\n";
		}
		else
		{
			printf "   Post-synchronisation commands failed\n";
		}
	}
}

# Exit uncleanly if we encountered any command errors
if ($command_errors)
{
	printf "\n   Encountered %d command errors\n", $command_errors;
	exit 1;
}

printf "\n\n   All actions completed successfully\n";
exit 0;
