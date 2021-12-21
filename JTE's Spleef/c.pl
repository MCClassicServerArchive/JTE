#!/usr/bin/perl
# command.pl
use warnings;
use strict;

our (%server);

$server{'commands'} = {
	HELP => [\&cmd_help,0],
	RULES => [\&cmd_rules,0,'Server rules list.'],
	HOWTO => [\&cmd_howto,0,'How to play.'],
	COLORS => [\&cmd_color,0,'Shows color codes.'],
	COLOR => [\&cmd_color,0],
	ME => [\&cmd_me,0,'Roleplaying action message.'],
	SAY => [\&cmd_say,100,'Send a global message.'],
	OP => [\&cmd_op,200,'Grant a user admin status.'],
	DEOP => [\&cmd_deop,200,'Revoke admin status.'],
	KICK => [\&cmd_kick,100,'Disconnect a user with the given message.'],
	BAN => [\&cmd_ban,100,'Ban a user by name.'],
	BANIP => [\&cmd_banip,100,'Ban a user by IP.'],
	UNBAN => [\&cmd_unban,100,'Unban a user.']
};

sub cmd_help() {
	my $id = shift;
	my $admin = $server{'users'}[$id]{'admin'};
	&send_msg($id,"Available commands:");
	&send_msg($id,"@ - Whisper a message to the named player.");
	foreach (keys %{$server{'commands'}}) {
		my @cmd = ($server{'commands'}{$_}[1], $server{'commands'}{$_}[2]);
		&send_msg($id,"/$_ - $cmd[1]") if ($cmd[1] && $admin >= $cmd[0]);
	}
}

sub cmd_rules() {
	my $id = shift;
	&send_msg($id,"Server rules:");
	&send_msg($id,"You can not build blocks.");
	&send_msg($id,"You can not break blocks after falling.");
	&send_msg($id,"You can not respawn after falling.");
	&send_msg($id,"No flying or teleporting hacks. (We'll know.)");
	&send_msg($id,"The users with &agreen&e names are server moderators.");
	&send_msg($id,"The users with &bcyan&e names are server admins.");
	&send_msg($id,"They will not cheat, they're probably here to play same as you.");
	&send_msg($id,"Do not annoy them.");
	&send_msg($id,"Now type /howto for how to play.");
}

sub cmd_howto() {
	my $id = shift;
	#&send_msg($id,"----------------------------------------------------------------");
	&send_msg($id,"How to play Spleef:");
	&send_msg($id,"When you join, you start in the pit at the bottom of the map.");
	&send_msg($id,"If other people are currently playing, they will be above you.");
	&send_msg($id,"When a game is not in progress, stairs leading up will appear.");
	&send_msg($id,"To play, climb the stairs and wait at the top wherever you like.");
	&send_msg($id,"When the platform changes to grass, it's time to play.");
	&send_msg($id,"Your objective is to break the grass out from under your");
	&send_msg($id,"opponents, causing them to fall back down to the pit, while they");
	&send_msg($id,"try to do the same to you. The last man standing wins.");
}

sub cmd_color() {
	my $id = shift;
	&send_msg($id,"Color codes:");
	&send_msg($id,"- &0%c0 &1%c1 &2%c2 &3%c3 &4%c4 &5%c5 &6%c6 &7%c7");
	&send_msg($id,"- &8%c8 &9%c9 &a%ca &b%cb &c%cc &d%cd &e%ce &f%cf");
	&send_msg($id,"Type any of these in your text and everything you");
	&send_msg($id,"type after it will be in the color displayed.");
}

sub cmd_me() {
	my $id = shift;
	unless (@_) {
		&send_msg($id,"No text to send.");
		return;
	}
	my $msg = "&d* ".$server{'users'}[$id]{'nick'}."&d @_";
	print &strip($msg);
	foreach (@{$server{'users'}}) {
		next unless defined($_);
		&send_raw($_->{'sock'},13,$id,$msg) if ($_->{'active'});
	}
}

sub cmd_say() {
	my $id = shift;
	unless (@_) {
		&send_msg($id,"No text to send.");
		return;
	}
	&global_msg("@_");
}

sub cmd_op() {
	my $id = shift;
	unless (@_) {
		&send_msg($id,"No user to op.");
		return;
	}
	my $save = 0;
	foreach my $name (@_) {
		if (($server{'admin'}{lc($name)}||0) >= 100) {
			&send_msg($id,"$name is already an admin.");
			next;
		}
		my $found = 0;
		foreach (@{$server{'users'}}) {
			next unless (defined($_) && $_->{'account'} eq $name);
			$found = 1;
			$save = 1;
			$server{'admin'}{lc($name)} = 100;
			$_->{'admin'} = 100;
			my $oid = $_->{'id'};
			&send_msg($id,"$name is now an admin.");
			&send_msg($oid,"You are now an admin.");
			&send_msg($oid,"Check &f/help&e again to see what you can do!");
			last;
		}
		&send_msg($id,"$name could not be found.") unless ($found);
	}
	&save_admins() if ($save);
}

sub cmd_deop() {
	my $id = shift;
	unless (@_) {
		&send_msg($id,"No user to deop.");
		return;
	}
	my $save = 0;
	foreach my $name (@_) {
		if (($server{'admin'}{lc($name)}||0) > ($server{'admin'}{lc($server{'users'}[$id]{'account'})}||0)) {
			&send_msg($id,"$name is higher ranked than you.");
			next;
		}
		my $found = 0;
		foreach (@{$server{'users'}}) {
			next unless (defined($_) && $_->{'account'} eq $name);
			$found = 1;
			$save = 1;
			undef $server{'admin'}{lc($name)};
			$_->{'admin'} = 0;
			my $oid = $_->{'id'};
			&send_login($oid);
			&send_msg($id,"$name is no longer an admin.") if ($id != $oid);
			&send_msg($oid,"You are no longer an admin.");
			last;
		}
		&send_msg($id,"$name could not be found.") unless ($found);
	}
	&save_admins() if ($save);
}

sub cmd_kick() {
	my $id = shift;
	my $knick = &strip(lc(shift));
	foreach (@{$server{'users'}}) {
		next unless (defined($_) && lc($_->{'account'}) eq $knick);
		&kick($_->{'id'},"@_");
		return;
	}
	&send_msg($id,"User '$knick' could not be found.");
}

sub cmd_ban() {
	my $id = shift;
	my $bnick = &strip(lc(shift));
	foreach (@{$server{'users'}}) {
		next unless (defined($_) && lc($_->{'account'}) eq $bnick);
		$server{'bans'}{$bnick} = 1;
		&save_bans();
		&kick($_->{'id'},'You have been banned.');
		return;
	}
	&send_msg($id,"User '$bnick' could not be found.");
}

sub cmd_unban() {
	my $id = shift;
	my $bnick = &strip(lc(shift));
	if ($server{'bans'}{$bnick}) {
		undef $server{'bans'}{$bnick};
		&save_bans();
		&send_msg($id,"$bnick has been unbanned.");
	}
	else { &send_msg($id,"$bnick is not in the ban list."); }
}

sub cmd_banip() {
	my $id = shift;
	my $bnick = &strip(lc(shift));
	foreach (@{$server{'users'}}) {
		next unless (defined($_) && lc($_->{'account'}) eq $bnick);
		$server{'ipbans'}{$_->{'sock'}->peerhost} = 1;
		&save_ipbans();
		&kick($_->{'id'},'You have been banned.');
		return;
	}
	&send_msg($id,"User '$bnick' could not be found.");
}

1;
