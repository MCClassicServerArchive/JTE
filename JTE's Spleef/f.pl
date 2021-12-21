#!/usr/bin/perl
# map.pl
use warnings;
use strict;
use POSIX;
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

our (%server);

my (@tiles) = (
	{ # Air
		light => 1
	},
	{ # Stone
		solid => 1
	},
	{ # Grass
		solid => 1
	},
	{ # Dirt
		solid => 1
	},
	{ # Cobblestone
		solid => 1
	},
	{ # Wood
		solid => 1
	},
	{ # Plant
		light => 1,
	},
	{ # Solid Admin Rock
		solid => 1
	},
	{ # Water (Active)
		liquid => 1
	},
	{ # Water (Passive)
		liquid => 1
	},
	{ # Lava (Active)
		liquid => 1
	},
	{ # Lava (Passive)
		liquid => 1
	},
	{ # Sand
		solid => 1
	},
	{ # Gravel
		solid => 1
	},
	{ # Gold ore
		solid => 1
	},
	{ # Iron ore
		solid => 1
	},
	{ # Coal
		solid => 1
	},
	{ # Tree Trunk/Stump
		solid => 1
	},
	{ # Tree Leaves
		solid => 1,
		light => 1
	},
	{ # Sponge
		solid => 1
	},
	{ # Glass
		solid => 1,
		light => 1
	},
	{ # Red Cloth
		solid => 1
	},
	{ # Orange Cloth
		solid => 1
	},
	{ # Yellow Cloth
		solid => 1
	},
	{ # Yellow-Green Cloth
		solid => 1
	},
	{ # Green Cloth
		solid => 1
	},
	{ # Green-Blue Cloth
		solid => 1
	},
	{ # Cyan Cloth
		solid => 1
	},
	{ # Blue Cloth
		solid => 1
	},
	{ # Blue-Purple Cloth
		solid => 1
	},
	{ # Purple Cloth
		solid => 1
	},
	{ # Indigo Cloth
		solid => 1
	},
	{ # Violet Cloth
		solid => 1
	},
	{ # Pink Cloth
		solid => 1
	},
	{ # Dark-Grey Cloth
		solid => 1
	},
	{ # Grey Cloth
		solid => 1
	},
	{ # White Cloth
		solid => 1
	},
	{ # Yellow flower
		light => 1,
	},
	{ # Red flower
		light => 1,
	},
	{ # Brown mushroom
		light => 1,
	},
	{ # Red mushroom
		light => 1,
	},
	{ # Gold
		solid => 1
	}
);

sub get_tileinfo() {
	my ($type) = @_;
	$type = 0 unless (defined($type));
	return $tiles[$type];
}

sub map_clearblock() {
	my ($x,$y,$z) = @_;
	my ($size_x,$size_y,$size_z) = @{$server{'map'}{'size'}};
	my $type = 0;
	&map_setblock($x,$y,$z,$type);
}

sub map_setblock() {
	my ($x,$y,$z,$type) = @_;
	my ($size_x,$size_y,$size_z) = @{$server{'map'}{'size'}};
	return if ($x < 0 || $x >= $size_x || $y < 0 || $y >= $size_y || $z < 0 || $z >= $size_z);
	my $old_type = &map_getblock($x,$y,$z);
	return if ($old_type == $type);

	# Change block
	my $display = $type;
	$display = &get_tileinfo($type)->{'display'} if (&get_tileinfo($type)->{'display'});
	$server{'map'}{'blocks'}[($y * $size_z + $z) * $size_x + $x] = $display;
	&global_blockchange($x,$y,$z,$display);
	undef $display if ($display == $type);
}

sub map_getblock() {
	my ($x,$y,$z) = @_;
	my ($size_x,$size_y,$size_z) = @{$server{'map'}{'size'}};
	return 0 if ($x < 0 || $x >= $size_x || $y < 0 || $y >= $size_y || $z < 0 || $z >= $size_z);
	return $server{'map'}{'blocks'}[($y * $size_z + $z) * $size_x + $x];
}

sub map_find() {
	if (open FILE,'<maps/'."@_".'.gz') {
		close FILE;
		return 1;
	}
	return 0;
}

sub map_load() {
	my ($file) = "@_";
	my $data;
	gunzip "maps/$file.gz" => \$data;
	return 0 unless $data;
	print "Loading map...\n";
	my ($version,$spawn_x,$spawn_y,$spawn_z,$spawn_rx,$spawn_ry,$size_x,$size_y,$size_z,@blocks) = unpack("cS>3c2S>3c*",$data);
	if ($version != $server{'info'}{'mapver'}) {
		print "Version number $version did not match.\n";
		return 0;
	}
	$server{'map'}{'name'} = $file;
	$server{'map'}{'spawn'} = [$spawn_x,$spawn_y,$spawn_z,$spawn_rx,$spawn_ry];
	$server{'map'}{'size'} = [$size_x,$size_y,$size_z];
	$server{'map'}{'blocks'} = \@blocks;
	print "Loaded map from $file\n";
	&global_mapchange();
	print "Map change complete.\n";
	return 1;
}

1;
