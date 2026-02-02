#!/usr/bin/env perl
#
# DXSpider install/update verification
#
# Use: verify_dxspider.pl [--mode auto|install|update] [--spider /spider] [--port 7300] [--verbose]
#
# Copy in /spider/local_cmd/verify_dxspider.pl  (optional)
#
# Kin EA3CV, ea3cv@cronux.net
#
# 20260202 v1.0
#

use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use File::Spec;
use Cwd qw(abs_path);
use POSIX qw(strftime);
use File::stat;

# ----------------------------
# Constants / help text
# ----------------------------
my $HELP_TEXT = <<"USAGE";
DXSpider install/update verification

Usage:
  verify_dxspider.pl --mode install
  verify_dxspider.pl --mode update
  verify_dxspider.pl --mode auto
  verify_dxspider.pl [--mode auto|install|update] [--spider /spider] [--port 7300] [--verbose]
  verify_dxspider.pl --help

Options:
  --mode     Verification profile:
             auto    = generic checks (default)
             install = stricter checks for a fresh install
             update  = checks suited for post-update validation
  --spider   Path to spider symlink or directory (default: /spider)
  --port     Telnet listener port to verify (default: 7300)
  --verbose  Print debug command execution to STDERR
  --help     Show this help

Exit codes:
  0 = OK
  1 = WARN present
  2 = FAIL present

Examples:
  sudo ./verify_dxspider.pl --mode install
  sudo ./verify_dxspider.pl --mode update
  ./verify_dxspider.pl --mode auto --verbose
USAGE

# ----------------------------
# Show help if no args were given
# ----------------------------
if (!@ARGV) {
  print $HELP_TEXT;
  exit 0;
}

# ----------------------------
# Config defaults
# ----------------------------
my $mode        = 'auto';     # auto|install|update
my $spider_link = '/spider';  # symlink or directory
my $port        = 7300;
my $verbose     = 0;
my $help        = 0;

GetOptions(
  'mode=s'   => \$mode,
  'spider=s' => \$spider_link,
  'port=i'   => \$port,
  'verbose'  => \$verbose,
  'help'     => \$help,
) or die "Invalid arguments. Use --help\n";

if ($help) {
  print $HELP_TEXT;
  exit 0;
}

$mode = lc $mode;
die "Invalid --mode (use auto|install|update)\n" unless $mode =~ /^(auto|install|update)$/;

# ----------------------------
# Result bookkeeping
# ----------------------------
my @OK;
my @WARN;
my @FAIL;

sub add_ok   { push @OK,   shift; }
sub add_warn { push @WARN, shift; }
sub add_fail { push @FAIL, shift; }

sub ts { strftime("%Y-%m-%d %H:%M:%S", localtime()); }

sub vlog {
  return unless $verbose;
  my ($msg) = @_;
  $msg //= '';
  $msg =~ s/\s+$//;
  CORE::warn("[verify_dxspider] $msg\n");
}

sub run_cmd {
  my ($cmd) = @_;
  return (127, "") if !$cmd;
  vlog("run: $cmd");
  my $out = `$cmd 2>&1`;
  my $rc = $? >> 8;
  return ($rc, $out);
}

sub bin_path {
  my ($bin) = @_;

  my %candidates = (
    systemctl => [qw(/bin/systemctl /usr/bin/systemctl /sbin/systemctl /usr/sbin/systemctl)],
    ss        => [qw(/bin/ss /usr/bin/ss /sbin/ss /usr/sbin/ss)],
    netstat   => [qw(/bin/netstat /usr/bin/netstat /sbin/netstat /usr/sbin/netstat)],
    git       => [qw(/usr/bin/git /bin/git /usr/local/bin/git)],
    sudo      => [qw(/usr/bin/sudo /bin/sudo)],
  );

  if (exists $candidates{$bin}) {
    for my $p (@{$candidates{$bin}}) {
      return $p if -x $p;
    }
  }

  my ($rc, $out) = run_cmd("command -v $bin");
  return undef unless $rc == 0;
  my $p = $out;
  $p =~ s/\s+$//;
  return $p if $p && -x $p;
  return undef;
}

sub have_cmd {
  my ($bin) = @_;
  return defined bin_path($bin) ? 1 : 0;
}

sub trim {
  my ($s) = @_;
  $s //= '';
  $s =~ s/^\s+//;
  $s =~ s/\s+$//;
  return $s;
}

# Run git in repo avoiding "dubious ownership": switch to repo owner when running as root
sub run_git_repo {
  my ($repo, $git_args) = @_;
  $git_args ||= '';

  my $git = bin_path('git');
  return (127, "git not found\n") unless $git;

  my $st = stat($repo);
  my $owner_uid = $st ? $st->uid : undef;

  if ($> == 0 && defined $owner_uid && $owner_uid != 0) {
    my $user = getpwuid($owner_uid);
    if ($user && have_cmd('sudo')) {
      my $sudo = bin_path('sudo');
      return run_cmd("$sudo -u '$user' $git -C '$repo' $git_args");
    }
  }
  return run_cmd("$git -C '$repo' $git_args");
}

# ----------------------------
# Locate /spider target
# ----------------------------
my $spider_real = abs_path($spider_link);

if (!-e $spider_link) {
  add_fail("Missing $spider_link (does not exist).");
} else {
  if (-l $spider_link) {
    my $t = readlink($spider_link);
    if (defined $t) {
      add_ok("$spider_link is a symlink -> $t");
    } else {
      add_warn("$spider_link is a symlink but readlink failed.");
    }
  } else {
    add_warn("$spider_link exists but is not a symlink (still OK if you install directly there).");
  }

  if (!defined $spider_real || !-d $spider_real) {
    add_fail("$spider_link does not resolve to a valid directory (resolved=" . (defined $spider_real ? $spider_real : "undef") . ").");
  } else {
    add_ok("$spider_link resolves to directory: $spider_real");
  }
}

# If spider dir unknown, stop early
if (!defined $spider_real || !-d $spider_real) {
  print_summary_and_exit();
}

# ----------------------------
# Key paths
# ----------------------------
my $perl_dir   = File::Spec->catdir($spider_real, 'perl');
my $local_dir  = File::Spec->catdir($spider_real, 'local');
my $ldata_dir  = File::Spec->catdir($spider_real, 'local_data');

my $cluster_pl = File::Spec->catfile($perl_dir,  'cluster.pl');
my $console_pl = File::Spec->catfile($perl_dir,  'console.pl');
my $dxvars_issue = File::Spec->catfile($perl_dir, 'DXVars.pm.issue');

my $dxvars_pm  = File::Spec->catfile($local_dir, 'DXVars.pm');
my $listeners_pm = File::Spec->catfile($local_dir, 'Listeners.pm');

# ----------------------------
# File presence checks
# ----------------------------
(-f $cluster_pl)   ? add_ok("Found $cluster_pl")   : add_fail("Missing $cluster_pl");
(-f $dxvars_issue) ? add_ok("Found $dxvars_issue") : add_warn("Missing $dxvars_issue (not fatal if already installed)");
(-f $console_pl)   ? add_ok("Found $console_pl")   : add_warn("Missing $console_pl (console shortcut 'dx' may not work).");

(-d $local_dir) ? add_ok("Found $local_dir") : add_warn("Missing $local_dir (config not created?)");
(-d $ldata_dir) ? add_ok("Found $ldata_dir") : add_warn("Missing $ldata_dir (may be created after first run)");

# ----------------------------
# DXVars sanity
# ----------------------------
if (-f $dxvars_pm) {
  add_ok("Found $dxvars_pm");

  my %need = (
    mycall    => 0,
    myalias   => 0,
    myname    => 0,
    myemail   => 0,
    mylocator => 0,
    myqth     => 0,
  );

  if (open my $fh, '<', $dxvars_pm) {
    while (my $line = <$fh>) {
      for my $k (keys %need) {
        if ($line =~ /\b(?:our\s+)?\$?$k\s*=\s*"(.*?)"\s*;/) {
          my $v = $1;
          $need{$k} = length(trim($v)) ? 1 : 0;
        }
      }
    }
    close $fh;

    my @missing = grep { !$need{$_} } sort keys %need;
    if (@missing) {
      add_warn("DXVars.pm appears incomplete (missing/empty: " . join(", ", @missing) . ").");
    } else {
      add_ok("DXVars.pm contains all required fields (mycall/myalias/myname/myemail/mylocator/myqth).");
    }
  } else {
    add_warn("Could not open $dxvars_pm: $!");
  }
} else {
  add_fail("Missing $dxvars_pm (DXSpider not configured).");
}

# ----------------------------
# Listener config sanity
# ----------------------------
if (-f $listeners_pm) {
  add_ok("Found $listeners_pm");
  my $enabled = 0;

  if (open my $lfh, '<', $listeners_pm) {
    while (my $line = <$lfh>) {
      next if $line =~ /^\s*#/;
      if ($line =~ /\[\s*"(?:0\.0\.0\.0|::)"\s*,\s*\Q$port\E\s*\]/) {
        $enabled = 1;
        last;
      }
    }
    close $lfh;
  } else {
    add_warn("Could not open $listeners_pm: $!");
  }

  if ($enabled) {
    add_ok("Listeners.pm: listener for port $port appears ENABLED (not commented).");
  } else {
    add_warn("Listeners.pm: no enabled listener found for port $port (file may still be commented).");
  }
} else {
  add_warn("Missing $listeners_pm (listener config may be default elsewhere, but usually should exist).");
}

# ----------------------------
# systemd checks
# ----------------------------
my $systemctl = bin_path('systemctl');
if ($systemctl) {
  my ($rca, $outa) = run_cmd("$systemctl is-active dxspider");
  my $active = trim($outa);
  ($rca == 0 && $active eq 'active')
    ? add_ok("systemd: dxspider service is ACTIVE.")
    : add_warn("systemd: dxspider service not active (is-active: '$active').");

  my ($rce, $oute) = run_cmd("$systemctl is-enabled dxspider");
  my $enabled = trim($oute);
  ($enabled eq 'enabled')
    ? add_ok("systemd: dxspider service is ENABLED at boot.")
    : add_warn("systemd: dxspider service is not enabled (is-enabled: '$enabled').");

  my ($rcu, $outu) = run_cmd("$systemctl cat dxspider");
  if ($rcu == 0 && $outu =~ /^\s*ExecStart=\s+\/usr\/bin\/perl\b/m) {
    add_warn("systemd unit: ExecStart has whitespace after '=' (should be 'ExecStart=/usr/bin/perl ...').");
  } elsif ($rcu == 0 && $outu =~ /^\s*ExecStart=\/usr\/bin\/perl\b/m) {
    add_ok("systemd unit: ExecStart looks correctly formatted.");
  } else {
    add_warn("systemd: could not inspect unit content (systemctl cat dxspider).");
  }
} else {
  add_warn("systemctl not found; skipping systemd checks.");
}

# ----------------------------
# Port listener check
# ----------------------------
my $listening = 0;

my $ss      = bin_path('ss');
my $netstat = bin_path('netstat');

if ($ss) {
  my ($rc, $out) = run_cmd("$ss -ltnp");
  if ($rc == 0 && $out =~ /:(\Q$port\E)\s+/) {
    $listening = 1;
    add_ok("Network: port $port is LISTENING (ss).");
  } else {
    add_warn("Network: port $port not listening (ss).");
  }
} elsif ($netstat) {
  my ($rc, $out) = run_cmd("$netstat -ltnp");
  if ($rc == 0 && $out =~ /:(\Q$port\E)\s+/) {
    $listening = 1;
    add_ok("Network: port $port is LISTENING (netstat).");
  } else {
    add_warn("Network: port $port not listening (netstat).");
  }
} else {
  add_warn("Neither 'ss' nor 'netstat' found; cannot verify listening port.");
}

if ($mode eq 'install' && !$listening) {
  if ($systemctl) {
    my ($rca, $outa) = run_cmd("$systemctl is-active dxspider");
    my $active = trim($outa);
    if ($rca == 0 && $active eq 'active') {
      add_fail("Install check: dxspider is active but port $port is not listening (listener likely not enabled).");
    }
  }
}

# ----------------------------
# Git checks (safe ownership)
# ----------------------------
my $git_dir = File::Spec->catdir($spider_real, '.git');
if (-d $git_dir && have_cmd('git')) {
  add_ok("Git: repository present ($git_dir).");

  my ($rcd, $desc) = run_git_repo($spider_real, "describe --tags --long --always");
  ($rcd == 0)
    ? add_ok("Git: describe: " . trim($desc))
    : add_warn("Git: git describe failed (rc=$rcd).");

  my ($rcc, $sha)  = run_git_repo($spider_real, "rev-parse --short HEAD");
  ($rcc == 0)
    ? add_ok("Git: current commit: " . trim($sha))
    : add_warn("Git: rev-parse failed (rc=$rcc).");

  if ($mode eq 'update' && $rcd != 0) {
    add_warn("Update check: git metadata seems incomplete (describe failed).");
  }
} else {
  if (!have_cmd('git')) {
    add_warn("Git: 'git' binary not found; cannot verify build metadata.");
  } else {
    add_warn("Git: no .git directory found under $spider_real (may be OK, but update verification will be limited).");
  }
}

# ----------------------------
# Basic permissions sanity
# ----------------------------
if (-f $cluster_pl) {
  (-r $cluster_pl) ? add_ok("Perms: cluster.pl is readable.") : add_fail("Perms: cluster.pl is not readable.");
}

my $dxbin = '/usr/local/bin/dx';
(-e $dxbin) ? add_ok("Found $dxbin (console shortcut).") : add_warn("Missing $dxbin (optional shortcut).");

# ----------------------------
# Report
# ----------------------------
print_summary_and_exit();

sub print_summary_and_exit {
  print "\nDXSpider verification (" . ts() . ")\n";
  print "Mode      : $mode\n";
  print "Spider dir: " . (defined $spider_real ? $spider_real : "(unresolved)") . "\n";
  print "Port      : $port\n";
  print "----------------------------------------\n";

  print_section("OK",   \@OK);
  print_section("WARN", \@WARN);
  print_section("FAIL", \@FAIL);

  my $exit = 0;
  $exit = 2 if @FAIL;
  $exit = 1 if !$exit && @WARN;

  print "\nExit code: $exit\n\n";
  exit $exit;
}

sub print_section {
  my ($name, $arr) = @_;
  print "$name (" . scalar(@$arr) . ")\n";
  for my $m (@$arr) {
    print "  - $m\n";
  }
  print "\n";
}
