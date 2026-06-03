#!/usr/bin/env perl

# Copyright (C) 2026 koha-dpkg-docker contributors
#
# This file is part of koha-dpkg-docker.
#
# koha-dpkg-docker is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# koha-dpkg-docker is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with koha-dpkg-docker; if not, see <https://www.gnu.org/licenses>.

# Auto-install required modules if missing
BEGIN {
    my @required = qw(Modern::Perl IPC::Cmd);
    my @missing;

    for my $module (@required) {
        eval "require $module; 1" or push @missing, $module;
    }

    if (@missing) {
        print "Installing missing Perl modules: " . join( ', ', @missing ) . "\n";
        system( 'cpan', '-i', @missing ) == 0
            or die "Failed to install modules: $!\n";
        exec( $^X, $0, @ARGV );    # Re-exec script with new modules
    }
}

use Modern::Perl;

use File::Temp qw(tempdir);
use Getopt::Long;
use Cwd      qw(abs_path getcwd);
use IPC::Cmd qw(run run_forked);

# Parse command line options
my $cleanup        = 1;        # Default to cleanup
my $help           = 0;
my $name           = '';
my $verbose        = 0;
my $warmup_timeout = 300;      # Default warmup timeout in seconds
my $force_cleanup  = 0;        # Force cleanup of existing instances
my $initial_docker_cleanup;    # Docker cleanup mode: undef, '', 'full', or 'Nd'

GetOptions(
    'cleanup!'                 => \$cleanup,
    'help|h'                   => \$help,
    'name=s'                   => \$name,
    'verbose|v'                => \$verbose,
    'warmup-timeout=i'         => \$warmup_timeout,
    'force-cleanup'            => \$force_cleanup,
    'initial-docker-cleanup:s' => \$initial_docker_cleanup,
) or die "Error in command line arguments\n";

if ($help) {
    print_help();
    exit 0;
}

# Save current working directory (the Koha repo being built)
my $koha_repo = $ENV{SYNC_REPO} || getcwd();
unless ( -d $koha_repo ) {
    $koha_repo = getcwd();
}

# Determine KDD instance name
my $instance_name;
if ($name) {
    $instance_name = $name;
    print "Using provided name: $instance_name for KDD instance\n";
} else {

    # Get short commit hash for naming the KDD instance
    $instance_name = qx{git rev-parse --short HEAD};
    chomp $instance_name;
    die "Failed to get commit hash. Are you in a git repository?\n"
        unless $instance_name;
    print "Using commit hash: $instance_name for KDD instance name\n";
}

# Create temporary directory for KDD
my $tmp_dir = tempdir( 'kdd-build-XXXXXX', TMPDIR => 1, CLEANUP => $cleanup );
print "Created temporary directory: $tmp_dir\n";

# Save original directory to restore later
my $original_dir = getcwd();

# Clone KDD into temp directory
if ( defined $initial_docker_cleanup && $initial_docker_cleanup ne '' ) {
    if ( $initial_docker_cleanup eq 'full' ) {
        print "Running full Docker cleanup...\n";
        run_cmd(
            "docker system prune -a -f --volumes",
            { exit_on_error => 1, real_time => $verbose }
        );
    } elsif ( $initial_docker_cleanup =~ /^(\d+)d$/ ) {
        print "Removing Docker images older than $1 days...\n";
        run_cmd(
            "docker image prune -a -f --filter until=${1}d",
            { exit_on_error => 0, real_time => $verbose }
        );
    } else {
        die "Invalid --initial-docker-cleanup value '$initial_docker_cleanup'. Use 'full' or 'Nd' (e.g. '7d')\n";
    }
} elsif ( defined $initial_docker_cleanup ) {

    # Flag passed without value: dangling images + volumes + networks
    print "Running Docker cleanup (dangling images, unused volumes and networks)...\n";
    run_cmd(
        "docker image prune -f",
        { exit_on_error => 0, real_time => $verbose }
    );
    run_cmd(
        "docker volume prune -f",
        { exit_on_error => 0, real_time => $verbose }
    );
    run_cmd(
        "docker network prune -f",
        { exit_on_error => 0, real_time => $verbose }
    );
}
print "Cloning koha-dpkg-docker...\n";
my $kdd_branch = $ENV{KDD_BRANCH} || 'unstable';
chdir($tmp_dir) or die "Cannot chdir to $tmp_dir: $!";
run_cmd(
    qq{git clone --branch $kdd_branch --single-branch --depth 1 https://github.com/openfifth/koha-dpkg-docker.git},
    { exit_on_error => 1, real_time => $verbose }
);

my $debs_out = $ENV{DEBS_OUT} || abs_path( qq{$koha_repo/../koha_debs} );
unless ( -d $debs_out ) {
    mkdir($debs_out) or die "Cannot mkdir $debs_out: $!";
}

my $kdd_home = "$tmp_dir/koha-dpkg-docker";
chdir($kdd_home) or die "Cannot chdir to $kdd_home: $!";

# Set up environment variables
$ENV{KDD_HOME}      = $kdd_home;
$ENV{SYNC_REPO}     = $ENV{SYNC_REPO} || $koha_repo;
$ENV{DEBS_OUT}      = $ENV{DEBS_OUT} || $debs_out;
$ENV{LOCAL_USER_ID} = qx{id -u};
chomp $ENV{LOCAL_USER_ID};
$ENV{KDD_IMAGE} = $ENV{KDD_IMAGE} || 'unstable';

# Copy defaults.env to .env
run_cmd(
    q{cp defaults.env .env},
    { exit_on_error => 1, real_time => $verbose }
);

# TODO: Rethink if we need to patch .env file with current environment variables
# or if kdd's environment variable override logic is sufficient.
{
    local @ARGV = ('.env');
    local $^I   = '';         # in-place editing
    while (<>) {
        if (/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/) {
            my ( $key, $val ) = ( $1, $2 );
            if ( exists $ENV{$key} ) {
                $_ = "$key=$ENV{$key}\n";
            }
        }
        print;
    }
}

# Build environment for kdd commands
my $kdd_env = {%ENV};
for my $key (qw(SYNC_REPO DEBS_OUT LOCAL_USER_ID KDD_IMAGE)) {
    delete $kdd_env->{$key} unless defined $ENV{$key} && $ENV{$key} ne '';
}

# Determine compose flags needed
my @compose_flags = (
    '--project-name', $instance_name,
    '-f', qq{$kdd_home/docker-compose.yml}
);

# Check for existing instance and clean up if needed
check_and_cleanup_existing_instance(
    $kdd_home, $instance_name,
    $force_cleanup
);

my $compose_flags = join( ' ', @compose_flags );

# Create log file for storing KDD startup logs
my $log_file = "$tmp_dir/kdd_startup.log";
print "Storing KDD logs to: $log_file\n";

# Launch KDD instance
print "Launching KDD instance '$instance_name' with flags: $compose_flags\n";

# Pull images quietly before launching
print "Pulling docker images...\n";
my $kdd_pull_cmd = "docker compose $compose_flags pull -q";
run_cmd(
    $kdd_pull_cmd,
    { exit_on_error => 1, real_time => 0, env => $kdd_env }
);

print "\n--- Run configuration ---\n";
print "instance:      $instance_name\n";
print "kdd_image:     $ENV{KDD_IMAGE}\n";
print "sync_repo:     $ENV{SYNC_REPO}\n";
print "debs_out:      $ENV{DEBS_OUT}\n";
print "kdd_branch:    $kdd_branch\n";
print "---\n\n";

print "Running build\n";
run_cmd(
    qq{docker compose $compose_flags up},
    { exit_on_error => 1, real_time => $verbose, env => $kdd_env }
);

# Cleanup
if ($cleanup) {
    print "Cleaning up KDD instance...\n";
    run_cmd(
        "docker compose $compose_flags down",
        { real_time => $verbose, env => $kdd_env }
    );
    print "Restoring original directory...\n";
    chdir($original_dir) or warn "Cannot chdir back to $original_dir: $!";
    print "Temporary directory will be cleaned up automatically.\n";
} else {
    print "Skipping cleanup. KDD instance '$instance_name' is still running.\n";
    print "Restoring original directory...\n";
    chdir($original_dir) or warn "Cannot chdir back to $original_dir: $!";
    print "Temporary directory: $tmp_dir\n";
    print "To cleanup manually, run:\n";
    print "  docker compose $compose_flags down\n";
    print "  rm -rf $tmp_dir\n";
}

exit 0;

# Subroutines

sub check_and_cleanup_existing_instance {
    my ( $kdd_home, $instance_name, $force_cleanup ) = @_;

    # Check if instance exists
    my $check_cmd =
        "docker compose --project-name $instance_name ps -q";
    my ( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) = IPC::Cmd::run(
        command => $check_cmd,
        verbose => 0,
    );

    if ( $success && $stdout_buf && @$stdout_buf ) {

        # Instance exists
        if ($force_cleanup) {
            print "Found existing instance '$instance_name', cleaning up...\n";
            my $cleanup_cmd =
                "docker compose --project-name $instance_name down";
            run_cmd( $cleanup_cmd, { real_time => 0 } );
        } else {
            die "Instance '$instance_name' already exists. Use --force-cleanup to remove it first.\n";
        }
    }
}

sub run_cmd {
    my ( $cmd, $params ) = @_;
    my $exit_on_error = $params->{exit_on_error} // 0;
    my $real_time     = $params->{real_time}     // 0;
    my $env           = $params->{env}           // {};

    my ( $success, $error_message, $full_buf, $stdout_buf, $stderr_buf ) = IPC::Cmd::run(
        command => $cmd,
        verbose => $real_time,
        timeout => 2 * 3600,        # 2 hour timeout for full build suite
        %$env ? ( env => $env ) : (),
    );

    if ( !$success && $exit_on_error ) {
        # Print tail of captured output for context
        if ( $stderr_buf && @$stderr_buf ) {
            my $tail = join( '', @$stderr_buf );
            my @lines = split /\n/, $tail;
            @lines = @lines[ -20 .. -1 ] if @lines > 20;
            print STDERR "--- Last stderr output ---\n" . join( "\n", @lines ) . "\n---\n";
        }
        check_and_cleanup_existing_instance( $kdd_home, $instance_name, 1 );
        die "Command failed: $error_message\n";
    }

    return $success;
}

sub print_help {
    print <<'HELP';
Usage: koha_build_runner.pl [OPTIONS]

Runs Koha build in an isolated KDD (Koha Dpkg Docker) instance.

This script:
  1. Creates a temporary directory
  2. Clones koha-dpkg-docker into it
  3. Launches a named KDD instance (using commit hash or custom name)
  4. Runs the full build suite
  5. Outputs generated packages to DEBS_OUT directory
  6. Optionally cleans up the instance and temporary directory

OPTIONS:
  --name <name>
      Name for the KDD instance. If not provided, uses the short commit hash
      from the current git repository.

  --force-cleanup
      Clean up any existing KDD instance with the same name before starting.
      Without this flag, the script will exit if an instance already exists.

  --initial-docker-cleanup[=MODE]
      Clean up Docker resources before starting. Modes:
        (no value)  Remove dangling images, unused volumes and networks (safe)
        full        Run 'docker system prune -a -f --volumes' (removes everything)
        Nd          Remove images older than N days (e.g. 7d)

  --warmup-timeout <seconds>
      Timeout in seconds to wait for KDD instance to be ready (default: 300).

  --cleanup / --no-cleanup
      Whether to cleanup the KDD instance and temp directory after running.
      Default: --cleanup

  -v, --verbose
      Show service logs during KDD warmup for debugging.

ENVIRONMENT VARIABLES:
  KDD_IMAGE         Koha docker image tag (default: 'unstable')
  KDD_BRANCH        KDD branch to use (default: 'unstable')
  SYNC_REPO         Path to Koha repository (default: current directory)
  DEBS_OUT          Path to 

EXAMPLES:
  # Run full build suite with cleanup (uses commit hash as name)
  ./koha_build_runner.pl

  # Run with a custom instance name
  ./koha_build_runner.pl --name my-build-run

  # Run with verbose logging to debug startup issues
  ./koha_build_runner.pl --verbose

  # Run build against a specific Koha branch with bookworm
  KDD_IMAGE=24.11 ./koha_build_runner.pl

HELP
}
