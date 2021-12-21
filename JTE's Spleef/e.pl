#!/usr/bin/perl
# serverinfo.pl
use warnings;
use strict;

our (%server);

sub load_serverinfo() {
	print "Loading configuration...\n";

	$server{'config'} = {};
	if (open FILE,'<config.txt') {
		foreach (<FILE>) {
			next if ($_ =~ /^#/);
			if ($_ =~ /(\S+) ?([^#\n\r]*)/) {
				my ($name,$data) = (lc($1),$2);
				$data = 1 unless (defined($data) && $data ne '');
				$server{'config'}{$name} = $data;
			}
		}
		close FILE;
	}

	print "Loading information on accounts...\n";

	$server{'admin'} = {};
	if (open FILE,'<admins.txt') {
		foreach (<FILE>) {
			if ($_ =~ /(\S+) ?(.*)/) {
				my ($name,$level) = (lc($1),$2);
				$level = 100 unless (defined($level) && $level ne '');
				$server{'admin'}{$name} = $level;
			}
		}
		close FILE;
	}

	$server{'bans'} = {};
	if (open FILE,'<banned.txt') {
		foreach (<FILE>) {
			$_ =~ s/[\r\n]//;
			$server{'bans'}{lc($_)} = 1;
		}
		close FILE;
	}

	$server{'ipbans'} = {};
	if (open FILE,'<banned-ip.txt') {
		foreach (<FILE>) {
			$_ =~ s/[\r\n]//;
			$server{'ipbans'}{$_} = 1;
		}
		close FILE;
	}
}

sub save_admins() {
	return unless(open FILE,'>admins.txt');
	foreach (keys %{$server{'admin'}}) {
		next unless defined($server{'admin'}{$_});
		print FILE "$_ ".$server{'admin'}{$_}."\n";
	}
	close FILE;
}

sub save_bans() {
	return unless(open FILE,'>banned.txt');
	foreach (keys %{$server{'bans'}}) {
		next unless defined($server{'bans'}{$_});
		print FILE "$_\n";
	}
	close FILE;
}

sub save_ipbans() {
	return unless(open FILE,'>banned-ip.txt');
	foreach (keys %{$server{'ipbans'}}) {
		next unless defined($server{'ipbans'}{$_});
		print FILE "$_\n";
	}
	close FILE;
}

1;
