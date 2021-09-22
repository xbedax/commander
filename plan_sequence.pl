#!/usr/bin/perl

# plans sequence 
# params:
#					start=<time>
#					members={<module_i>:<time_i>}
# example:	plan_sequence start=0230 members=ZVJezirko:10,ZVVjezd:15,ZVStred:20,ZVLouka:10

use IO::Handle;
use strict;
use warnings;
use lib '.';
use iconfig;
#use Data::Dumper;

our %conftbl = ();
my  %configtab = ();
my $mainconfig = "../files/promenne.php";
my $testconfig = "./config.loc";
my $filehandle;	
my $configtype;
my $args = join (' ', @ARGV);
my $TESTING;

if ( -r $mainconfig) {
	open ($filehandle, "$mainconfig") || die "Plan_seq: Can't open $mainconfig: $!\n";
	$configtype = 'PHP';
} elsif ( -r $testconfig) {
	open ($filehandle, "$testconfig") || die "Plan_seq: Can't open $testconfig: $!\n";
	$configtype = 'PERL';
} else {
	die "Plan_seq: Can't find $mainconfig!\n";
}

if ($configtype eq 'PHP') {
	read_php_config ($filehandle, \%configtab, 'WORKING');
} else {
	read_config ($filehandle, \%configtab);
}
close $filehandle;

if (defined $configtab{'Global'}->{'TESTING'} ) {
	$TESTING = $configtab{'Global'}->{'TESTING'};
}
my $configtable = $configtab{'Global'}->{'ConfigTable'};
#my $logtable = $configtab{'Global'}->{'LogTable'};
unless ( defined $TESTING ) {
	$TESTING='NO';
}

if ( -r $configtable) {
	open ($filehandle, "$configtable") || do {# 						printlog (1, "Plan_seq: Can't open $configtable: $!");
												exit;
											}
}
read_config ($filehandle, \%conftbl);

my $starttimes;
my $members;

foreach my $argument (@ARGV) {
	if ( $argument =~ /start=(.+)/ ){
		$starttimes = $1;
		$starttimes =~ s/'//g;
	#												print "StartTimes--$starttimes\n";
	}
	if ( $argument =~ /members=(.+)/ ){
		$members = $1;
		$members =~ s/'//g;
	#												print "Members--$members\n";
	}
}

my @starts = split ( ",", $starttimes);

while ($members =~ /:/) {
	$members =~ s/^([^,]*),*(.*)/$2/;
	my ($member, $duration) = split (/:/, $1);
#																		print " $member -->> $duration \n";
	unless ( defined $conftbl{$member}->{Class}){
#																		printlog (1, "Plan_seq: Unknown sequence member: $member");
		print "Neexistující člen posloupnosti $member. Žádné změny nebyly provedeny.";
		exit;
	}
	unless ( defined ( $conftbl{$member}->{'Req_state'} ) ) {
		print "Modul $member není možné zařadit do posloupnosti, ignoruji.\n";
	}
		
	if ($conftbl{$member}->{'Req_state'} eq 'TIME' ){
		if ( $#starts > 0 ) {
			print "Pozor - modul $member neumožňuje naplánovat více intervalů. \n"
		}
		$conftbl{$member}{'State_from'} = $starts[0];			
#																		print "  number of ints: $#starts \n";
		for ( my $idx = 0; $idx <= $#starts; $idx++ ) {
			$starts[$idx] = addtime ($starts[$idx], $duration);
		}
		$conftbl{$member}{'State_to'} = $starts[0];
		print "$member ... Od $conftbl{$member}->{'State_from'} do $conftbl{$member}->{'State_to'}\n";
		next;
	}
	if ($conftbl{$member}->{'Req_state'} eq 'TIMEI' ) {
		my @timeints = ();
		for(my $idx = 0; $idx <= $#starts; $idx++) {
			$timeints[$idx] = $starts[$idx];
			$starts[$idx] = addtime ($starts[$idx],$duration);
			$timeints[$idx] =  $timeints[$idx] . "-" . $starts[$idx];
		}
		$conftbl{$member}{'State_on_int'} = join (',', @timeints);
		print "$member ... $conftbl{$member}->{'State_on_int'}\n";
		next;
#																		print " intervals $member -- $conftbl{$member}{'State_on_int'} \n";
	}
	print "Modul $member není možné zařadit do posloupnosti, ignoruji.\n";
}

open ($filehandle, "$configtable") || do {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
											exit;
											};
	
my @conflines = ();
while (my $line = <$filehandle>) {
	push (@conflines, $line);
}
close $filehandle;

open ($filehandle, ">$configtable") || do {# 							printlog (1, "Plan_seq: Can't write lines $configtable: $!");
											exit;
										};
my $cursection;
foreach my $line (@conflines) {
	my $activeline = $line;
	$activeline =~ s/#.*//;
	if( $activeline =~ /\[([^\[]+)\]/ ){
		$cursection = $1;
	}
	if( $activeline =~ /State_from/ ) {
		my $newtime = $conftbl{$cursection}{'State_from'};
		$line =~ s/=\s*(\d\d\d\d)/=$newtime/;
	}
	if( $activeline =~ /State_to/ ) {
		my $newtime = $conftbl{$cursection}{'State_to'};
		$line =~ s/=\s*(\d\d\d\d)/=$newtime/;
	}
	if( $activeline =~ /State_on_int/) {
		my $newstateonint = $conftbl{$cursection}{'State_on_int'};
		$line =~ s/=\s*(.*)/=$newstateonint/;
	}
	
	print $filehandle $line;
}
close $filehandle;
print "\n HOTOVO\n";
exit;
										

#===============================================================================
# Procedures
#===============================================================================

sub addtime
{
	my $timefrom = shift;
	my $timelen = shift;
	
	my $hours = int( $timefrom / 100 );
	my $mins = $timefrom % 100;
	$mins = $mins + $timelen;
	
	$hours = ($hours + int( $mins / 60 )) % 24;
	$mins = $mins % 60;

	return sprintf ("%02d", $hours) . sprintf ("%02d", $mins);
}


# TODO
# remove shared subroutines
#