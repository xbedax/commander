#!/usr/bin/perl

# sets condition
# params:
#					members='{<module_i>}'
#					condition='<condition_string>'
# example:	set_condition members='ZVJezirko:10,ZVVjezd:15,ZVStred:20,ZVLouka:10' condition='RDAY:2'

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
}else {
	$TESTING = 'NO';
}
my $configtable = $configtab{'Global'}->{'ConfigTable'};
#my $logtable = $configtab{'Global'}->{'LogTable'};
																		print "Config: $configtable \n";
unless ( defined $TESTING ) {
	$TESTING='NO';
}

if ( -r $configtable) {
	open ($filehandle, "$configtable") || do {# 						printlog (1, "Plan_seq: Can't open $configtable: $!");
												exit;
											}
}
read_config ($filehandle, \%conftbl, 'WORKING');

my $memberslist;
my $condition;



foreach my $argument (@ARGV) {
	if ( $argument =~ /condition=(.+)/ ){
		$condition = $1;
		$condition =~ s/'//g;
	#												print "StartTimes--$starttimes\n";
	}
	if ( $argument =~ /members=(.+)/ ){
		$memberslist = $1;
		$memberslist =~ s/'//g;
	#												print "Members--$members\n";
	}
}

my @members = split ( ",", $memberslist);
#																		print Dumper @members;
foreach my $member (@members) {
	unless( defined $conftbl{$member}->{'Class'}){
#																		printlog (1, "Set_cond: Unknown module: $member");
		print "Neexistující modul $member. Ignoruji.\n";		
		next;
	}
	if ( defined ($conftbl{$member}->{'Req_state'}) && (($conftbl{$member}->{'Req_state'} eq 'TIME') || ($conftbl{$member}->{'Req_state'} eq 'TIMEI') || ($conftbl{$member}->{'Req_state'} eq 'SPILL')) ){
		$conftbl{$member}{'Condition'} = $condition;			
		print "$member ... $conftbl{$member}->{'Condition'}\n";
	} else {
		print "Modul $member neumožňuje nastavit podmínku, ignoruji. \n";
		next;
	} 
}
	
open ($filehandle, "$configtable") || do {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
											exit;
										};

my @conflines = ();
while (my $line = <$filehandle>) {
	push (@conflines, $line);
}
close $filehandle;

open ($filehandle, ">$configtable") || do {# 								printlog (1, "Plan_seq: Can't write lines $configtable: $!");
											exit;
										};
my $cursection;
foreach my $line (@conflines) {
	my $activeline = $line;
	$activeline =~ s/#.*//;
	if( $activeline =~ /\[([^\[]+)\]/ ){
		$cursection = $1;
	}
	if( $activeline =~ /Condition/ ) {
		my $newcondition = $conftbl{$cursection}{'Condition'};
		$line =~ s/=.*/=$newcondition/;
	}
	
	print $filehandle $line;
#	print $line;
}
close $filehandle;
print "\n HOTOVO\n";
exit;

#===============================================================================
# Procedures
#===============================================================================



# TODO
# remove shared subroutines
#