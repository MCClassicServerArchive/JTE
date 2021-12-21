#!/usr/bin/perl
# core.pl
use warnings;
use strict;
use IO::Socket;
use IO::Select;
use Time::HiRes qw( time );
require 'b.pl';
require 'c.pl';
require 'd.pl';
require 'e.pl';
require 'f.pl';

our (%server);

# Internal stuff (Leave this alone)
$server{'info'} = {
	version => 7,
	salt => int(rand(0xFFFFFFFF))-0x80000000,
	rawlog => 0,
	mapver => 1
};

# Gets ready to wait for connections
sub open_sock() {
	$server{'socketset'} = new IO::Select();
	$server{'lsock'} = IO::Socket::INET->new(
		Listen    => 5,
		LocalPort => $server{'config'}{'port'},
		Proto     => 'tcp'
	) or die("Socket error: $!\n");
	# We won't make the same mistake the official server does:
	# Keep one EXTRA slot open for accepting (in order to deny) requests over the limit.
	# Dumbasses...
	$server{'lsock'}->listen($server{'config'}{'max-players'}+1);
	$server{'socketset'}->add($server{'lsock'});
}

# Handles new connections
sub handle_connection() {
	my $sock = shift;
	# Find an open player slot.
	my $id;
	for ($id = 0; $id < $server{'config'}{'max-players'}; $id++) {
		last unless defined($server{'users'}[$id]{'active'});
	}
	my $ip = $sock->peerhost;
	if ($server{'ipbans'}{$ip}) {
		print "$ip tried to join, but is on the ban list.\n";
		&send_kick($sock,'You are still banned.');
		$sock->close();
		return;
	}
	# None found.
	if ($id >= $server{'config'}{'max-players'}) {
		print "Connection refused: Server is full.\n";
		&send_kick($sock,'Server is full.');
		$sock->close();
		return;
	}
	# Connections from the same person
	my $connect_count = 0;
	foreach (@{$server{'users'}}) {
		next unless (defined($_) && defined($_->{'sock'}) && $_->{'active'});
		$connect_count++ if ($sock->peerhost eq $_->{'sock'}->peerhost);
	}
	if ($connect_count >= $server{'config'}{'max-connections'}) {
		print "$ip tried to join, but is already logged in $connect_count times.\n";
		&send_kick($sock,'Connection refused: You are already logged in.');
		$sock->close();
		return;
	}
	# Add the new player and wait for their login.
	print "Client $id connected.\n";
	$server{'users'}[$id]{'timeout'} = time()+15;
	$server{'users'}[$id]{'active'} = 0;
	$server{'users'}[$id]{'sock'} = $sock;
	$server{'users'}[$id]{'id'} = $id;
	$server{'socketset'}->add($sock);
}

# Handles dead connections
sub handle_disconnect() {
	my $id = shift;
	my $nick = $server{'users'}[$id]{'nick'};
	my $sock = $server{'users'}[$id]{'sock'};
	$server{'users'}[$id]{'active'} = 0;
	&global_die($id);
	delete $server{'users'}[$id];
	$server{'socketset'}->remove($sock);
	$sock->close();
	if (defined($nick)) { &global_msg("- $nick&e disconnected."); }
	else { print "$id disconnected.\n"; };

	&game_checkvictory();
	foreach (@{$server{'users'}}) {
		next unless ($_ && $_->{'active'});
		return;
	}
	&map_load($server{'config'}{'idle_map'});
}

# Strips color codes from a message;
sub strip() {
	my $msg = shift;
	$msg =~ s/&[0-9a-f]//g;
	return $msg;
}

# Disconnects a user.
sub kick() {
	my ($id,$msg) = @_;
	&send_kick($server{'users'}[$id]{'sock'},$msg);
	&global_msg("- ".$server{'users'}[$id]{'account'}."&e has been kicked ($msg)") if ($server{'users'}[$id]{'account'});
	&handle_disconnect($id);
}

sub game_checkvictory() {
	return if ($server{'victory'} || $server{'map'}{'name'} ne $server{'config'}{'game_map'});
	my $count = 0;
	my $winner;
	foreach (@{$server{'users'}}) {
		next unless (defined($_) && $_->{'active'} && $_->{'ready'});
		$count++;
		$winner = $_;
	}
	if ($count == 0) { &global_msg("== The match ends in a draw! =="); }
	elsif ($count == 1) { &global_msg("== ".$winner->{'nick'}."&e is the victor! =="); }
	if ($count <= 1) {
		$server{'map_change'} = floor(time)+10;
		$server{'victory'} = 1;
	}
}

sub update_position() {
	my ($user) = @_;
	return unless (defined($user->{'old_pos'}) && defined($user->{'old_rot'}));
	my @old_pos = @{$user->{'old_pos'}};
	my @old_rot = @{$user->{'old_rot'}};
	my @base_pos = @{$user->{'base_pos'}};
	my @pos = @{$user->{'pos'}};
	my @rot = @{$user->{'rot'}};
	my $id = $user->{'id'};

	if ($server{'map'}{'name'} eq $server{'config'}{'idle_map'}) {
		if ($pos[0]/32 > 2 && $pos[0]/32 < $server{'map'}{'size'}[0]-2
		&& $pos[2]/32 > 2 && $pos[2]/32 < $server{'map'}{'size'}[2]-2
		&& $pos[1]/32 > $server{'map'}{'size'}[1]+1) {
			unless ($user->{'ready'}) { $user->{'ready'} = 1; }
		}
		else {
			if ($user->{'ready'}) { $user->{'ready'} = 0; }
		}
	}
	elsif ($server{'map'}{'name'} eq $server{'config'}{'game_map'}) {
		if ($user->{'ready'}) {
			unless (defined($server{'map_change'})) {
				if ($pos[1]/32 < 3) {
					&global_msg("- ".$user->{'nick'}."&e forfeits!");
					$user->{'ready'} = 0;
				}
				elsif ($pos[1]/32 < $server{'map'}{'size'}[1]) {
					&global_msg("- ".$user->{'nick'}."&e is down!");
					$user->{'ready'} = 0;
				}
				unless ($user->{'ready'}) { &game_checkvictory(); }
			}
		}
		else {
			if ($pos[1]/32 > $server{'map'}{'size'}[1]+1) {
				$pos[1] -= 64;
				&send_raw($_->{'sock'},8,-1,@pos,@rot);
			}
		}
	}

	my $changed = 0;
	$changed |= 1 if ($old_pos[0] != $pos[0] || $old_pos[1] != $pos[1] || $old_pos[2] != $pos[2]);
	$changed |= 2 if ($old_rot[0] != $rot[0] || $old_rot[1] != $rot[1]);
	$changed |= 4 if (abs($pos[0]-$base_pos[0]) > 32 || abs($pos[1]-$base_pos[1]) > 32 || abs($pos[2]-$base_pos[2]) > 32);
	$changed |= 4 if (($pos[0] == $old_pos[0] && $pos[1] == $old_pos[1] && $pos[2] == $old_pos[2])
					&& ($pos[0] != $base_pos[0] || $pos[1] != $base_pos[1] || $pos[2] != $base_pos[2]));
	$changed = 0 if ($user->{'hide'});

	# Anti-lag hack
	#$pos[0] += ($pos[0]-$old_pos[0])*8;
	#$pos[2] += ($pos[2]-$old_pos[2])*8;

	if ($changed & 4) {
		foreach (@{$server{'users'}}) {
			next unless defined($_);
			next if ($user == $_ && !$user->{'showself'});
			&send_raw($_->{'sock'},8,$id,@pos,@rot);
			$user->{'base_pos'} = \@pos;
		}
	}
	elsif ($changed == 1) {
		foreach (@{$server{'users'}}) {
			next unless defined($_) && $_->{'active'};
			next if ($user == $_ && !$user->{'showself'});
			&send_raw($_->{'sock'},10,$id,$pos[0]-$old_pos[0],$pos[1]-$old_pos[1],$pos[2]-$old_pos[2]);
		}
	}
	elsif ($changed == 2) {
		foreach (@{$server{'users'}}) {
			next unless defined($_) && $_->{'active'};
			next if ($user == $_ && !$user->{'showself'});
			&send_raw($_->{'sock'},11,$id,@rot);
		}
	}
	elsif ($changed == 3) {
		foreach (@{$server{'users'}}) {
			next unless defined($_) && $_->{'active'};
			next if $user == $_ && !$user->{'showself'};
			&send_raw($_->{'sock'},9,$id,$pos[0]-$old_pos[0],$pos[1]-$old_pos[1],$pos[2]-$old_pos[2],@rot);
		}
	}

	@{$user->{'old_pos'}} = @{$user->{'pos'}};
	@{$user->{'old_rot'}} = @{$user->{'rot'}};
}

# Main function
sub main() {
	print "Echidna Tribe Spleef Server\n";
	if ($server{'info'}{'rawlog'}) { open FILE,'>raw.log'; close FILE; }
	&load_serverinfo();
	&heartbeat(1);
	&map_generate(16,16,16) unless &map_load($server{'config'}{'idle_map'});
	$server{'map'}{'name'} = $server{'config'}{'idle_map'};
	&open_sock();
	$server{'ping'} = time();
	print "Ready.\n\n";
	while(1) {
		my ($ready) = IO::Select->select($server{'socketset'}, undef, undef, 0.2);

		foreach my $sock (@{$ready}) {
			if ($sock == $server{'lsock'}) { &handle_connection($sock->accept()); next; }
			my $id;
			foreach (@{$server{'users'}}) {
				next unless (defined($_) && defined($_->{'sock'}) && $sock == $_->{'sock'});
				$id = $_->{'id'};
				last;
			}
			unless (defined($id)) {
				$server{'socketset'}->remove($sock);
				$sock->close();
			}
			my $buffer;
			unless ($sock->connected && $sock->recv($buffer,0xFFFF)) { &handle_disconnect($id); next; }
			if (defined($server{'clearbuffer'})) { $server{'users'}[$id]{'buffer'} = ''; }
			else { $server{'users'}[$id]{'buffer'} = &handle_packet($id,($server{'users'}[$id]{'buffer'}||'').$buffer); }
		}
		undef $server{'clearbuffer'} if (defined($server{'clearbuffer'}) && $server{'clearbuffer'} < time);

		# Ping the players every half a second
		if (time() >= $server{'ping'}+0.5) {
			&send_ping();
			$server{'ping'} = time();
		}

		# Update the player's positions and orientations only once every so often.
		foreach (@{$server{'users'}}) {
			if (defined($_->{'timeout'}) && time() >= $_->{'timeout'}) {
				&kick($_->{'id'},"You must send a login.");
				next;
			}
			next unless (defined($_) && $_->{'active'});
			if (defined($_->{'services_timer'}) && time() >= $_->{'services_timer'}) {
				#&send_msg($_->{'id'},"Currently in map '$server{'map'}{'name'}'");
				&send_msg($_->{'id'},'This server is running on Echidna Tribe services.');
				&send_msg($_->{'id'},'Type &f/help&e for commands, and be sure to check &f/rules&e.');
				undef $_->{'services_timer'};
			}
			&update_position($_);
		}

		if ($server{'map'}{'name'} eq $server{'config'}{'idle_map'} && floor(time) > ($server{'ready_msg'}||0)+10) {
			my $ready = 0;
			my $total = 0;
			foreach (@{$server{'users'}}) {
				next unless (defined($_) && $_->{'active'});
				$total++;
				$ready++ if ($_->{'ready'});
			}
			&global_msg("Waiting for players. ($ready / $total)") if ($total > 0);
			if ($ready >= 2 && !$server{'map_change'}) {
				$server{'map_change'} = floor(time)+20;
				&global_msg("Map changing in 20 seconds.");
			}
			$server{'ready_msg'} = floor(time);
		}

		&heartbeat(0) if (floor(time) >= $server{'heartbeat'}+45); # Update the heartbeat every 45 seconds.

		if (defined($server{'count'}) && $server{'count'} >= 0 && ($server{'countdown'} - floor(time)) <= $server{'count'}) {
			if ($server{'count'} > 0) {
				&global_msg("Starting in $server{'count'}!");
				$server{'count'}--;
			}
			else {
				&global_msg("== &2SPLEEF!! &e==");
				undef $server{'count'};
			}
		}

		if (defined($server{'map_change'}) && floor(time) > $server{'map_change'}) {
			if ($server{'map'}{'name'} eq $server{'config'}{'idle_map'}) {
				my $ready = 0;
				foreach (@{$server{'users'}}) {
					next unless (defined($_) && $_->{'active'} && $_->{'ready'});
					$ready++;
				}
				if ($ready >= 2) { &map_load($server{'config'}{'game_map'}); }
				else { &global_msg("Not enough players are ready."); }
			}
			elsif ($server{'map'}{'name'} eq $server{'config'}{'game_map'}) {
				&map_load($server{'config'}{'idle_map'});
			}
			undef $server{'map_change'};
		}
	}
}

&main();
