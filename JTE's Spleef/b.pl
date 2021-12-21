#!/usr/bin/perl
# packet.pl
use warnings;
use strict;
use Digest::MD5 qw(md5_hex);
use IO::Compress::Gzip qw(gzip $GzipError);
use POSIX;

our (%server);

# Packet formats
my @packets = (
	['cA64A64c',\&handle_login], #0
	[''], #1
	[''], #2
	['na1024c'], #3
	['n3'], #4
	['n3c2',\&handle_blockchange], #5
	['n3c'], #6
	['cA64n3c2'], #7
	['cn3c2',\&handle_input], #8
	['c6'], #9
	['c4'], #10
	['c3'], #11
	['c'], #12
	['cA64',\&handle_chat], #13
	['A64'] #14
);

# Gets the length of a given packet type
sub get_packet_len() {
	# Yes, this DOES actually turn the packet format
	# string into the length of the message itself...!
	my $format = $packets[shift][0];

	$format =~ s/(\D)(\D)/$1.'1'.$2/ge; # No number? Presume 1.
	$format =~ s/(\D)$/$1.'1'/ge;

	$format =~ s/[Aac](\d+)/+$1/g; # 1 byte
	$format =~ s/[Sn](\d+)/+($1*2)/g; # 2 byte
	$format =~ s/[LN](\d+)/+($1*4)/g; # 4 byte

	# Cut the leading +
	$format =~ s/^\+//g;

	return eval $format || 0; # And finally calculate it.
}

# Takes decoded packet and logs it.
sub raw_log() {
	return unless ($server{'info'}{'rawlog'});
	my ($dst,$type,@args) = @_;
	my $format = $packets[$type][0];
	open RAW,'>>raw.log';
	if ($dst > 0) { print RAW "Recieved $type from ".(abs($dst)-1).":\n"; }
	else { print RAW "Sent $type to ".(abs($dst)-1).":\n"; }
	while ($format =~ /(\D)([<>]?)(\d*)/g) {
		my ($type,$endian,$num) = ($1,$2,$3);
		$num = 1 unless $num ne '';
		if ($type eq 'A') { # Strings
			my $mask = $type.$endian.$num;
			if ($mask eq 'A64') { $mask = 'String'; }
			else { $mask = 'Err'.$mask; }
			print RAW "$mask: ".shift(@args)."\n";
		}
		elsif ($type eq 'a') { # Don't bother to log raw data
			print RAW "raw$num\n";
			shift @args;
		}
		else { # Numbers of numbers
			my $mask = $type.$endian;
			if ($mask eq 'c') { $mask = 'Byte'; }
			elsif ($mask eq 'n') { $mask = 'Short'; }
			elsif ($mask eq 'N') { $mask = 'Long'; }
			else { $mask = 'Err'.$mask; }
			for (my $i = 0; $i < $num; $i++) {
				print RAW "$mask: ".shift(@args)."\n";
			}
		}
	}
	print RAW "\n";
	close RAW;
}

# Sends a packet to a game client by socket.
sub send_raw() {
	my $sock = shift;
	return unless ($sock);
	#my $id = $server{'id'}{$sock};
	#$id = $server{'config'}{'max_players'} unless (defined($id));
	#&raw_log(-($id+1),@_) if ($_[0] != 1);
	print $sock pack('c'.$packets[$_[0]][0],@_);
}

# Sends a login packet (Server name/motd)
sub send_login() {
	my ($id) = @_;
	&send_raw($server{'users'}[$id]{'sock'},0,$server{'info'}{'version'},$server{'config'}{'name'},$server{'config'}{'motd'},0);
}

# Sends a packet 1 to everyone on the server to let them know they're still connected.
sub send_ping() {
	foreach (@{$server{'users'}}) {
		next unless defined($_);
		&send_raw($_->{'sock'},1) if ($_->{'active'});
	}
}

# Sends a map change
# TODO: Do this in a seperate thread or take a break after every packet to poll somehow.
sub send_map() {
	my ($id) = @_;
	$server{'users'}[$id]{'active'} = 0;
	my ($sock) = $server{'users'}[$id]{'sock'};
	&send_raw($sock,2);
	my $level = pack('L>c*',$server{'map'}{'size'}[0]*$server{'map'}{'size'}[1]*$server{'map'}{'size'}[2],@{$server{'map'}{'blocks'}});
	my $buffer;
	gzip \$level => \$buffer;
	undef $level;
	my $count = 1;
	my $num_packets = ceil(length($buffer)/1024);
	while ($buffer) {
		my $len = length($buffer);
		$len = 1024 if ($len > 1024);
		my $send;
		($send,$buffer) = unpack("a1024a*",$buffer);
		&send_raw($sock,3,$len,$send,floor($count*100/$num_packets));
		$count++;
	}
	&send_raw($sock,4,@{$server{'map'}{'size'}});
	$server{'users'}[$id]{'pos'} = [
		($server{'map'}{'size'}[0]/2)*32+16,
		2*32+16,
		($server{'map'}{'size'}[2]/2)*32+16
	];
	$server{'users'}[$id]{'rot'} = [ 1,1 ];
	&send_spawn($id);
	foreach (@{$server{'users'}}) {
		next unless (defined($_) && defined($_->{'sock'}) && $_->{'id'} != $id);
		&send_raw($sock,7,$_->{'id'},$_->{'nick'},@{$_->{'pos'}},@{$_->{'rot'}});
	}
}

sub global_mapchange() {
	my $level = pack('L>c*',$server{'map'}{'size'}[0]*$server{'map'}{'size'}[1]*$server{'map'}{'size'}[2],@{$server{'map'}{'blocks'}});
	my $buffer;
	gzip \$level => \$buffer;
	undef $level;
	my $count = 1;
	my $num_packets = ceil(length($buffer)/1024);
	foreach (@{$server{'users'}}) {
		next unless defined($_) && $_->{'active'};
		&global_die($_->{'id'});
		undef $_->{'old_pos'};
		undef $_->{'old_rot'};
		undef $_->{'base_pos'};
	}
	foreach (@{$server{'users'}}) {
		next unless defined($_) && $_->{'active'};
		&send_raw($_->{'sock'},0,$server{'info'}{'version'},"&cLoading map","Please wait...",0);
		&send_raw($_->{'sock'},2);
	}
	while ($buffer) {
		my $len = length($buffer);
		$len = 1024 if ($len > 1024);
		my $send;
		($send,$buffer) = unpack("a1024a*",$buffer);
		foreach (@{$server{'users'}}) {
			next unless defined($_) && $_->{'active'};
			&send_raw($_->{'sock'},3,$len,$send,floor($count*100/$num_packets));
		}
		$count++;
	}
	my @respawn_pos = ( ($server{'map'}{'size'}[0]/2)*32+16, 2*32+16, ($server{'map'}{'size'}[2]/2)*32+16 );
	my @respawn_rot = (1,1);
	foreach (@{$server{'users'}}) {
		next unless defined($_) && $_->{'active'};
		&send_raw($_->{'sock'},4,@{$server{'map'}{'size'}}); # Send the map size

		# Save their old position
		my $old_pos = $_->{'pos'};
		my $old_rot = $_->{'rot'};

		# Set their respawn point to the pit
		$_->{'pos'} = \@respawn_pos;
		$_->{'rot'} = \@respawn_rot;
		&send_spawn($_->{'id'});

		# Teleport them back where they were.
		my @pos = @{$old_pos};
		if ($server{'map'}{'name'} eq $server{'config'}{'idle_map'}) {
			$pos[1] = $respawn_pos[1]; # Don't save your Y when going to the idle map. (No auto-ready)
			if ($pos[0] < 2*32+16) { $pos[0] = 2*32+16; }
			elsif ($pos[0] > ($server{'map'}{'size'}[0]-3)*32+16) { $pos[0] = ($server{'map'}{'size'}[0]-3)*32+16; }
			if ($pos[2] < 2*32+16) { $pos[2] = 2*32+16; }
			elsif ($pos[2] > ($server{'map'}{'size'}[2]-3)*32+16) { $pos[2] = ($server{'map'}{'size'}[2]-3)*32+16; }
		}
		elsif ($server{'map'}{'name'} eq $server{'config'}{'game_map'}) {
			if ($_->{'ready'}) { $pos[1] = ($server{'map'}{'size'}[1]+1)*32+16; }
			else { $pos[1] = $respawn_pos[1]; }
		}
		$_->{'pos'} = $old_pos;
		$_->{'rot'} = $old_rot;
		@{$_->{'old_pos'}} = @{$old_pos};
		@{$_->{'old_rot'}} = @{$old_rot};
		@{$_->{'base_pos'}} = @{$old_pos};
		&send_raw($_->{'sock'},8,-1,@pos,@{$old_rot});
	}
	foreach (@{$server{'users'}}) {
		next unless defined($_) && $_->{'active'};
		&global_spawn($_->{'id'},$_->{'nick'},@{$_->{'pos'}},@{$_->{'rot'}});
	}
	#$server{'clearbuffer'} = floor(time)+1;
	if ($server{'map'}{'name'} eq $server{'config'}{'game_map'}) {
		$server{'map_change'} = floor(time)+180;
		$server{'victory'} = 0;
		$server{'countdown'} = floor(time)+10;
		$server{'count'} = 5;
	}
}

# Sends a local block change to one specific id.
sub send_blockchange() {
	my ($id,$x,$y,$z,$t) = @_;
	&send_raw($server{'users'}[$id]{'sock'},6,$x,$y,$z,$t);
}

# Sends a new block type for a given position to everyone.
sub global_blockchange() {
	my ($x,$y,$z,$t) = @_;
	#print "Tile at $x $y $z changing to $t...\n";
	foreach (@{$server{'users'}}) {
		next unless defined($_);
		&send_raw($_->{'sock'},6,$x,$y,$z,$t) if ($_->{'active'});
	}
}

# Sends a spawn message to a player about themselves.
# This teleports them to where the server thinks they are (or should be) and sets their respawn point.
sub send_spawn() {
	my ($id) = @_;
	&send_raw($server{'users'}[$id]{'sock'},7,-1,$server{'users'}[$id]{'nick'},@{$server{'users'}[$id]{'pos'}},@{$server{'users'}[$id]{'rot'}});
	$server{'users'}[$id]{'active'} = 1;
	$server{'users'}[$id]{'last_move'} = time();
	@{$server{'users'}[$id]{'old_pos'}} = @{$server{'users'}[$id]{'pos'}};
	@{$server{'users'}[$id]{'old_rot'}} = @{$server{'users'}[$id]{'rot'}};
	@{$server{'users'}[$id]{'base_pos'}} = @{$server{'users'}[$id]{'pos'}};
}

# Sends a spawn message to everyone using the given id, nick, etc.
sub global_spawn() {
	my ($id,$nick,$x,$y,$z,$rx,$ry) = @_;
	foreach (@{$server{'users'}}) {
		next unless defined($_) && defined($_->{'sock'});
		my $id = $id;
		next if ($_->{'id'} == $id && !$_->{'showself'});
		&send_raw($_->{'sock'},7,$id,$nick,$x,$y,$z,$rx,$ry) if ($_->{'active'});
	}
}

# Sends a player/bot disconnect message to everyone for the given id.
# This makes the object disappear.
sub global_die() {
	my ($id) = @_;
	foreach (@{$server{'users'}}) {
		next unless defined($_) && defined($_->{'sock'});
		next if ($_->{'id'} == $id && !$_->{'showself'});
		&send_raw($_->{'sock'},12,$id) if ($_->{'active'});
	}
}

# Relays chat messages
sub send_chat() {
	my ($id,$msg) = @_;
	print $server{'users'}[$id]{'account'}.": ".&strip($msg)."\n";
	my $nick = $server{'users'}[$id]{'nick'};
	if ($nick =~ /&[0-9a-f]/) { $msg = $server{'users'}[$id]{'nick'}."&f: $msg"; }
	else { $msg = $server{'users'}[$id]{'nick'}.": $msg"; }
	foreach (@{$server{'users'}}) {
		next unless defined($_);
		&send_raw($_->{'sock'},13,$id,$msg) if ($_->{'active'});
	}
}

# Sends a server message
sub send_msg() {
	my ($id,$msg) = @_;
	print 'Server->'.$server{'users'}[$id]{'account'}.': '.&strip($msg)."\n";
	&send_raw($server{'users'}[$id]{'sock'},13,-1,$msg);
}

# Sends a server message to EVERYONE
sub global_msg() {
	my ($msg) = @_;
	print &strip($msg)."\n";
	foreach (@{$server{'users'}}) {
		next unless defined($_);
		&send_raw($_->{'sock'},13,-1,$msg) if ($_->{'active'});
	}
}

# Sends a kick
sub send_kick() {
	my ($sock,$msg) = @_;
	&send_raw($sock,14,$msg);
}

# Handles incoming packets of all kinds of messages...
sub handle_packet() {
	my ($id,$buffer) = @_;
	my $sock = $server{'users'}[$id]{'sock'};
	my $type;
	while ($buffer) {
		($type,$buffer) = unpack("ca*",$buffer); # Get the message type.
		next if ($type == -1);

		# Unknown message type recieved!!
		# This happens when I've made terrible mistakes in my code,
		# a player is trying to cause some mischief with fake packets,
		# or when Notch has updated the client and I haven't caught up yet.
		unless (defined($packets[$type][1])) {
			print "Recieved unhandled packet type $type from $id\n";
			return '';
			#&kick($id,'Unhandled message.');
		}
		return $buffer if (length($buffer) < &get_packet_len($type)); # The whole message isn't there yet.

		my @args = unpack($packets[$type][0].'a*',$buffer); # Unpack the arguments...
		$buffer = pop @args;
		&raw_log($id+1,$type,@args) unless ($type == 8);
		&{$packets[$type][1]}($id,@args); # Call the handler.
		return '' unless ($sock->connected); # User disconnected or was kicked.
	}
	return '';
}

# Handles the login packet
sub handle_login() {
	my ($id,$version,$name,$verify,$type) = @_;
	undef $server{'users'}[$id]{'timeout'};
	if ($server{'bans'}{lc($name)}) {
		print "$name tried to join, but is on the ban list.\n";
		&kick($id,'You are still banned.');
		return;
	}
	if ($version != $server{'info'}{'version'}) {
		print "Unknown client version number $version recieved from $name.\n";
		&kick($id,'Unknown client version!');
		return;
	}
	if ($server{'config'}{'heartbeat'} && $server{'config'}{'verify'}) {
		if ($verify eq '--') {
			&kick($id,'This server is secure. The IP URL doesn\'t work.');
			return;
		}
		# Do you know how much harder this would be to do in Java?
		# How many more lines and error checking nonsense?
		$verify = substr($verify,0,32);
		my $md5 = md5_hex($server{'info'}{'salt'},$name);
		$md5 =~ s/^0//g;
		$verify =~ s/^0//g;
		if ($md5 ne $verify) {
			print "$id tried to log in as $name, but $md5 didn't match $verify\n";
			my $ip = $server{'users'}[$id]{'sock'}->peerhost;
			$server{'failed_logins'}{$ip} = 0 unless (defined($server{'failed_logins'}{$ip}));
			$server{'failed_logins'}{$ip}++;
			if ($server{'failed_logins'}{$ip} > 3) {
				$server{'ipbans'}{$ip} = 1;
				&save_ipbans();
				&kick($id,'IP BANNED: Spoof attempt detected.');
				return;
			}
			&kick($id,'Login failed. (Try again in a moment.)');
			return;
		}
		# Do you?? God, why do you always gotta make things
		# so much harder than they really need to be...
	}
	foreach (@{$server{'users'}}) {
		next unless (defined($_) && $_->{'active'} && lc($_->{'account'}) eq lc($name));
		print "$name tried to join, but is already here!\n";
		&kick($id,'Login failed: You\'re already connected.');
		return;
	}
	$server{'users'}[$id]{'account'} = $name;
	$server{'users'}[$id]{'admin'} = $server{'admin'}{lc($name)} || 0;
	if ($name eq 'JTE') { $server{'users'}[$id]{'nick'} = '&c'.$name; }
	elsif ($server{'users'}[$id]{'admin'} >= 200) { $server{'users'}[$id]{'nick'} = '&b'.$name; }
	elsif ($server{'users'}[$id]{'admin'} >= 100) { $server{'users'}[$id]{'nick'} = '&a'.$name; }
	else { $server{'users'}[$id]{'nick'} = $name; }
	$name = $server{'users'}[$id]{'nick'};
	&global_msg("- $name&e is connecting...");
	&send_login($id);
	&send_map($id);
	$server{'users'}[$id]{'active'} = 0;
	&global_msg("- $name&e joined the game.");
	$server{'users'}[$id]{'active'} = 1;
	#$server{'users'}[$id]{'showself'} = 1;
	&global_spawn($id,$name,@{$server{'users'}[$id]{'pos'}},@{$server{'users'}[$id]{'rot'}});
	$server{'users'}[$id]{'services_timer'} = time()+10;
}

# Client creates or destroys a block
sub handle_blockchange() {
	my ($id,$pos_x,$pos_y,$pos_z,$action,$type) = @_;
	if ($type > 41) {
		print "WARNING: Unknown block type $type selected by ".$server{'users'}[$id]{'account'}."; Changed to stone.\n";
		$type = 1;
	}
	# Don't build using the hidden block types
	if ($type <= 0 || ($type >= 7 && $type <= 11) || ($type >= 14 && $type <= 16)) {
		&kick($id,'Hack detected.');
		return;
	}
	# Don't break blocks that are out of the client's range! >:O
	if (abs($pos_x - floor($server{'users'}[$id]{'pos'}[0]/32)) > 5
	|| abs($pos_y - floor($server{'users'}[$id]{'pos'}[1]/32)) > 5
	|| abs($pos_z - floor($server{'users'}[$id]{'pos'}[2]/32)) > 5) {
		$server{'bans'}{lc($server{'users'}[$id]{'account'})} = 1;
		&save_bans();
		&kick($id,'BANNED: Hack detected.');
		return;
	}
	$type = $server{'users'}[$id]{'build'} if (defined($server{'users'}[$id]{'build'}) && $type == 1);
	if ($action == 0) {
		if (&map_getblock($pos_x,$pos_y,$pos_z) == 7 && $server{'users'}[$id]{'admin'} < 100) { &kick($id,'Hack detected.'); }
		if ($server{'users'}[$id]{'ready'} && !$server{'count'}) { &map_clearblock($pos_x,$pos_y,$pos_z); }
		else { &send_blockchange($id,$pos_x,$pos_y,$pos_z,&map_getblock($pos_x,$pos_y,$pos_z)); }
	}
	elsif ($action == 1) {
		&send_blockchange($id,$pos_x,$pos_y,$pos_z,&map_getblock($pos_x,$pos_y,$pos_z));
		#&map_setblock($pos_x,$pos_y,$pos_z,$type);
	}
	else {
		print "Unknown action type $action recieved from ".$server{'users'}[$id]{'account'}."\n";
		&kick($id,'Unknown action.');
		return;
	}
}

# Client input
sub handle_input() {
	my ($id,$this_id,$pos_x,$pos_y,$pos_z,$rot_x,$rot_y) = @_;
	my ($size_x,$size_y,$size_z) = @{$server{'map'}{'size'}};
	if ($this_id != -1) {
		&kick($id,'Hack detected.');
		return;
	}
	if ($rot_y > 64 || $rot_y < -64) {
		&kick($id,'Hack detected.');
		return;
	}
	if ($pos_x < 0 || $pos_y < 0 || $pos_z < 0
	|| $pos_x >= $size_x*32 || $pos_y >= ($size_y+3)*32+16 || $pos_z >= $size_z*32) {
		$server{'bans'}{lc($server{'users'}[$id]{'account'})} = 1;
		&save_bans();
		&kick($id,'BANNED: Left the map.');
		return;
	}
	if (abs($pos_x-$server{'users'}[$id]{'pos'}[0]) > 8
	|| abs($pos_z-$server{'users'}[$id]{'pos'}[2]) > 8
	|| ($pos_y-$server{'users'}[$id]{'pos'}[1]) > 14) {
		if ($server{'users'}[$id]{'speeding'} > 5) { # Third strike, they're speed hacking.
			$server{'bans'}{lc($server{'users'}[$id]{'account'})} = 1;
			&save_bans();
			&kick($id,"BANNED: Speedhack.");
		}
		else { $server{'users'}[$id]{'speeding'}++; } # First two frames, give them a warning. (Maybe they just used R to respawn)
	}
	else { $server{'users'}[$id]{'speeding'} = 0; } # Remove warnings if speed hack not detected.
	@{$server{'users'}[$id]{'pos'}} = ($pos_x,$pos_y,$pos_z);
	@{$server{'users'}[$id]{'rot'}} = ($rot_x,$rot_y);
}

# When someone chats, I know!
sub handle_chat() {
	my ($id,$this_id,$msg) = @_;
	if ($this_id != -1) {
		&kick($id,'Hack detected.');
		return;
	}
	$msg =~ s/%c([0-9a-f])/&$1/g; # Change %c to proper color codes.
	$msg =~ s/&[0-9a-f](&[0-9a-f])/$1/g; # Remove duplicate/multiple color codes so only the last one takes effect.
	$msg =~ s/&[0-9a-f]$//g; # Remove any color codes at the end of the line.
	return unless ($msg); # Ignore messages which are, therefore, blank.

	if ($msg =~ m|^/(\S+)\s*(.*)|) {
		my $cmd = uc($1);
		my @args = split(/ /,$2);
		if (defined($server{'commands'}{$cmd}) && $server{'users'}[$id]{'admin'} >= $server{'commands'}{$cmd}[1]) {
			print $server{'users'}[$id]{'account'}." admins: $cmd\n" if ($server{'commands'}{$cmd}[1] > 0);
			&{$server{'commands'}{$cmd}[0]}($id,@args);
		}
		else { &send_msg($id,"Unknown command '$cmd'"); }
	}
	elsif ($msg =~ /^xyzzy/) { &send_msg($id,"Nothing happens."); }
	elsif ($msg =~ /^@\s*(\S+) (.+)/) { # Message to a specific person
		my $found = 0;
		if (!defined($1) || $1 eq '' || $1 =~ /@/) {
			&send_chat($id,$msg);
			return;
		}
		$msg = '&d@'.$server{'users'}[$id]{'nick'}.':&f '.$2;
		&send_raw($server{'users'}[$id]{'sock'},13,$id,$msg);
		foreach (@{$server{'users'}}) {
			next unless defined($_) && ($_->{'active'}) && ($_->{'account'} eq $1);
			$found = 1;
			&send_raw($_->{'sock'},13,$id,$msg);
			return;
		}
		unless ($found) { &send_msg($id,"Couldn't find '$1'"); }
	}
	else { &send_chat($id,$msg); } # Normal map chat
}

1;
