#!/usr/bin/perl

# performs requested command immediately
#	- verifies that current and working config are the same
#	- writes settings to both config files
#	- issues requested command
# params:
#					module=<module_name>
#					manual_state=<requested state>
#					manual_date_to=<date>
#					manual_time_to=<time>
#					manual_length=<minutes_to_keep>

# example:	immediate_command module='ZVStred' manual_state='ON' manual_length='15'
# example:	immediate_command module='Air' manual_state='ON' manual_date_to='31.07.2018' manual_time_to='2200'
# example:	immediate_command module='Air' manual_state='ON' manual_time_to='2200'   ... without date specified, current date is used
# example:	immediate_command module='Air' manual_state='ON' manual_date_to='01.02.2021'   ... without time specified, current time is substitued
# example:	immediate_command module='ZZDoor' manual_state='20' manual_length='1'
# example:	immediate_command module='ZZDoor' manual_state='CLEAR'

# Script state
#	simplified command building
#	empty date_to allowed
#	solved long running commands (setpulse)
#	roll-back step change if mover fails
#	manual_time_from support added
#	CLEAR state implemented
#	time_to / date_to substitutions repaired
#	unified write config procedure
#	config manipulation procedures moved to iconfig


use IO::Handle;
use IO::Socket;
use IO::Socket::INET;
use IO::Select;
use strict;
use warnings;
use Module::Runtime qw(
        $module_name_rx is_module_name check_module_name
        module_notional_filename require_module);

use lib '.';
use iconfig '1.03.05';
use iconfig qw (get_curstep write_curstep read_last_states write_last_states compare_endtime write_manual compare_config);

use icomm '2.01.01';
use Data::Dumper;

my  %configphpwork = ();
my  %configphpact = ();
my  %configmain = ();
my  %configact = ();
my  @worklines = ();
my  @actlines = ();

our %registered_protocols;
our %gwtab = ();
 
my $mainphpconfig = "../files/promenne.php";
my $testphpconfig = "./config/files/promenne.php";
my $filehandle;	
my $configtype;
my $args = join (' ', @ARGV);
our $connected = 0;
our @sockets_ready;
our $rsconnection;
my $remote;																# jen zpetna kompatibilita, smazat
my $port;																# jen zpetna kompatibilita, smazat
our $connection_retries = 3;
our $Select_client = new IO::Select();
our $tempfolder;
our $stepsuffix;
our $resetstep;
my $stattable;
my $checktime;

my $TESTING;
our $loglevel = 1;


# Read configurations (main, working, current)

if ( -r $mainphpconfig) {
	open ($filehandle, "$mainphpconfig") || die "Immediate_command: Can't open $mainphpconfig: $!\n";
#	$configtype = 'PHP';
} elsif ( -r $testphpconfig) {
	open ($filehandle, "$testphpconfig") || die "Immediate_command: Can't open $testphpconfig: $!\n";
#	$configtype = 'PHP';
} else {
	die "Immediate_command: Can't find $mainphpconfig!\n";
}
unless ( read_php_config ($filehandle, \%configphpwork, 'WORKING') ) {
	print "Poškozená PHP W konfigurace!\n";
}
seek ($filehandle, 0, 0 );
unless ( read_php_config ($filehandle, \%configphpact, 'ACTIVE') ) {
	print "Poškozená PHP  A konfigurace!\n";
}
close $filehandle;

if ( -r $configphpwork{'Global'}->{'IniterMainConfig'} ) {
	open ( $filehandle, $configphpwork{'Global'}->{'IniterMainConfig'} ) || do  {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
											print "Nelze otevřít hlavní konfiguraci" . $configphpwork{'Global'}->{'IniterMainConfig'} . ", končím!";
											exit;
											};
	read_config ( $filehandle, \%configmain );
	close $filehandle;
}
our $logfile = $configmain{'log'}->{'file'};
our $logto = $configmain{'log'}->{'logto'};
$loglevel = $configmain{'log'}->{'level'};

# Set GLOBAL VARIABLES	
$TESTING = $configmain{'Global'}->{'TESTING'};
unless ( defined $TESTING ) {
	$TESTING='NO';
}
if ( defined (	$configmain{'RSGW'}->{'Connection_retries'} ) ) {
	$connection_retries = $configmain{'RSGW'}->{'Connection_retries'};
}
if ( defined (	$configmain{'log'}->{'level'} ) ) {
	$connection_retries = $configmain{'log'}->{'level'};
}
our ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
$year += 1900;
$mon += 1;

											printlog (1, "Imm_Com: -- Starting -- Params: $args");
#											print "Imm_Com: -- Starting -- ($logfile) Params: $args";

$resetstep = $configmain{'Stepper'}->{'ResetStep'};
my $gwfile = $configmain{'Comm'}->{'GatewayTable'};
# compare working and active config
open ($filehandle, $configphpwork{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Imm_Com: Can't read lines $configtable: $!");
											print "Nelze otevřít pracovní konfiguraci $configphpwork{'Global'}->{'ConfigTable'}, končím!";
											exit;
											};
while (my $line = <$filehandle>) {
	push (@worklines, $line);
}
close $filehandle;
open ($filehandle, $configphpact{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Imm_com: Can't read lines $configtable: $!");
											print "Nelze otevřít aktivní konfiguraci, končím!";
											exit;
											};
while ( my $line = <$filehandle> ) {                 
	push ( @actlines, $line );
}
seek ( $filehandle, 0, 0 );
read_config ($filehandle, \%configact);
close $filehandle;

unless (compare_config ( \@actlines, \@worklines ) ) {
	print "Pracovní a provozní konfigurace nejsou shodné. Musíte nejprve obnovit současnou konfiguraci, nebo aktivovat novou konfiguraci, aby bylo možno pokračovat.<P> Končím!<P>";
	exit;
}

# load protocols, gateways
my $openresult = opendir (DIR, './protocols') or do {
											print "Nelze načít konfigurace protokolů, končím!\n";
																		printlog (2, "Unable to open protocols directory");
	exit;
};
#	print "xx\n";
my @protocolfiles =  readdir (DIR);
closedir (DIR);

foreach my  $protocolfile(@protocolfiles) {
	unless ( $protocolfile =~ /^proto_/ ) {
		next;
	}
#																		print $protocolfile . "\n";
	$protocolfile =~ s/\.pm$//;
	require_module 'protocols::'.$protocolfile;
}
																		
# foreach my $prot (keys %registered_protocols){
																		# print "Protocol $prot -> " . $registered_protocols{$prot}{'modulename'} . " registered.";
# }

if ( -r $gwfile) {
	open ($filehandle, "$gwfile") || die "INITER: Can't open $filehandle: $!\n";
} else {
	die "INITER: Nelze nalézt $filehandle!\n";
}
read_config ($filehandle, \%gwtab);
close ($filehandle);

# Parse command line parameters
my $manualstate;
my $module;
my $manualdate;
my $manualtime;
my $manuallength;


foreach my $argument (@ARGV) {
	if ( $argument =~ /module=(.+)/ ){
		$module = $1;
		$module =~ s/'//g;
	}
	if ( $argument =~ /manual_state=(.+)/ ){
		$manualstate = $1;
		$manualstate =~ s/'//g;
	}
	if ( $argument =~ /.*manual_date_to=(.+)/) {
		$manualdate = $1;
		$manualdate =~ s/'//g;
	}
	if ($argument =~ /.*manual_time_to=(.+)/) {
		$manualtime = $1;
		$manualtime =~ s/'//g;
	}
	if ( $argument =~ /.*manual_length=(.+)/) {
		$manuallength = $1;
		$manuallength =~ s/'//g;
	}
}
my $targettime = time();
#Check commandline syntax
unless ( defined $module ) {
	print "Není zadán cílový modul. Končím!";
	exit;
}
unless ( defined $manualstate ) {
	print "Není zadán požadovaný stav. Končím!";
	exit;
}
my $moduletype;
if ( defined ( $configact{$module}->{'Req_state'} ) ) {
	$moduletype = $configact{$module}->{'Req_state'};
} else {
	print "Požadavek na změnu neznámého modulu: $module. Končím!";
	exit;
}
my $syntaxcheck = 0;
if ( ($moduletype =~ /TIME/) || ($moduletype =~ /ON/) || ($moduletype =~ /OFF/) || ($moduletype =~ /HEAT/) ){
	if ( ($manualstate eq 'OFF' ) || ( $manualstate eq 'ON' ) ) {
		$syntaxcheck = 1;
	}
}
if ( ($moduletype =~ /STEPVENT/) || ($moduletype =~ /STEPHUMVENT/) ){
	if ( $manualstate =~ /\d+/ ) {
		$syntaxcheck = 1;
	}
# Check runtime environment
	if ( defined ($configmain{'Global'}->{'TempFolder'} ) ) {     #tohle presunout do if moduletype==stepvent ...
		$tempfolder = $configmain{'Global'}->{'TempFolder'};
	} else {
		print "Chyba konfigurace - nelze zjistit adresář pro uložení aktuálních kroků. Končím!";
		exit;
	}

	if ( defined ( $configmain{'Stepper'}->{'StepSuffix'} ) ) {
		$stepsuffix = $configmain{'Stepper'}->{'StepSuffix'};
	} else {
		print "Chyba konfigurace - nelze zjistit soubor uložení aktuálního kroku. Končím!";
		exit;
	}

}
if ( $manualstate =~ /CLEAR/i ) {
	$syntaxcheck = 1;
}
unless ( $syntaxcheck ) {
	print "Pro zvolený modul nelze nastavit, nebo nesprávný požadovaný stav. Končím!";
	exit;
}

# Read last states table into actual config table hash
if ( defined ($configmain{'Global'}->{'StatTable'} ) ) {     #tohle presunout do if moduletype==stepvent ...
	$stattable = $configmain{'Global'}->{'StatTable'};
} else {
	print "Chyba konfigurace - nelze zjistit soubor posledních stavů. Končím!";
	exit;
}
if (open ($filehandle, "$stattable") ) {
	$checktime = read_last_states ($filehandle, \%configact);
	close $filehandle;
}else{
																		printlog (1, "INITER: Can't open $stattable: $!");
	foreach my $key (keys %configact) {
		$configact{$key}{'LastState'} = 'N/A';
	}
												
}

# manual state length case
if ( defined ( $manuallength ) ) {
#											print "ManualLength--$manuallength\n";
	$targettime = time() + $manuallength * 60;

#											print "targetsec: " . time() . "->$targetsec\n";
}	
# manual date / time to case
if ( defined ( $manualtime ) || defined ($manualdate)) {
#											print "ManualDate--$manualdate\n";
	my ($csec,$cmin,$chour,$cmday,$cmon,$cyear,$cwday,$cyday,$cisdst) = localtime();
	$cyear += 1900;
	$cmon += 1;


	if ( defined ( $manualtime ) ) {
		$chour = int ( $manualtime  / 100 );
		$cmin = $manualtime % 100;
	}
	if ( defined ( $manualdate ) ) {
		( $cmday, $cmon, $cyear ) = split ( /\./, $manualdate );
	}

	$targettime = timelocal (0, $cmin, $chour, $cmday, $cmon - 1, $cyear - 1900);	
#											print "TargetTime--$targettime\n";
}	

open ( $filehandle, ">" . $configphpwork{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
											print "Nelze zapisovat do pracovní konfigurace, končím!";
											exit;
											};
$configact{$module}{'Manual_time_to'} = writetime ( $targettime );
$configact{$module}{'Manual_state'} = $manualstate;
$configact{$module}{'_Manual_setting_member'} = 1;
write_manual ($filehandle, \@worklines, \%configact);
close $filehandle;
											
open ( $filehandle, ">" . $configphpact{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
											print "Nelze zapisovat do aktuální konfigurace, končím!";
											exit;
											};
write_manual ($filehandle, \@actlines, \%configact);

close $filehandle;

if ( $manualstate =~ /CLEAR/i ) {
	print "Odstraněn manuální stav\n";
	exit;
}

#issue immediate command
print "Příprava příkazu ...\n";
#exit; 																	#+++ SMAZAT - testing +++
#$remote = $configmain{'RSGW'}->{'NetAddress'};							# tohle by se melo smazat
#$port = $configmain{'RSGW'}->{'NetPort'}; 								# tohle by se melo smazat


my $command;
#my $quidoaddr;
#my $portnum;
my $continuecallback;
my $performedcommand;
my $curstat = '';
my $protocol_module;
my $sendresult;
my $evalstring;
my $targetmodule;
my %commandparam;


unless ( $configact{$module}->{'Class'} =~ /pair$|group*/ ) {
	$protocol_module = $registered_protocols{$configact{$module}->{'Proto'}}{'modulename'};
	$targetmodule = $module;
}

#if ( defined ( $configact{$module}->{'RS_address'} ) ){
#	$quidoaddr = $configact{$module}->{'RS_address'};
#	$portnum = $configact{$module}->{'Port_num'};
#}
# Switch OFF requested
if ( $manualstate eq 'OFF' ) {
	$performedcommand = 'SetState';
	$commandparam{'command'} = 'SetState';
	$commandparam{'targetstate'} = 'OFF';
	$commandparam{'device'} = $configact{$module}->{'Class'};
	$commandparam{'protocol'} = $configact{$module}->{'Proto'};
	$commandparam{'busaddress'} = $configact{$module}->{'Bus_address'};
	$commandparam{'port'} = $configact{$module}->{'Port_num'};
	$protocol_module = $registered_protocols{$configact{$module}->{'Proto'}}{'modulename'};	
}
# Switch ON requested
if ( $manualstate eq 'ON' ) {
	$performedcommand = 'SetState';
	$commandparam{'command'} = 'SetState';
	$commandparam{'targetstate'} = 'ON';
	$commandparam{'device'} = $configact{$module}->{'Class'};
	$commandparam{'protocol'} = $configact{$module}->{'Proto'};
	$commandparam{'busaddress'} = $configact{$module}->{'Bus_address'};
	$commandparam{'port'} = $configact{$module}->{'Port_num'};
	$protocol_module = $registered_protocols{$configact{$module}->{'Proto'}}{'modulename'};
}

#																	print "About to set module<BR>\n";
# Requested state contains digits -> set value
if ( $manualstate =~ /\d+/ ) {
#																	print "Manual step setting<BR>\n";
	$manualstate =~ s/$[^\d]*(\d+).*/$1/;
#																	print "   reqstep - $manualstate <BR>\n";
	my $curstep = get_curstep ( $module );
#																	print "   curstep - $curstep <BR>\n";				
	my $interval; 
	if ( $curstep > $manualstate ) {
		$interval = $curstep - $manualstate;
		$protocol_module = $registered_protocols{$configact{$configact{$module}->{'Port_Down'}}->{'Proto'}}{'modulename'};
		$targetmodule = $configact{$module}->{'Port_Down'};
		
	} else {
		$interval = $manualstate - $curstep;
		$protocol_module = $registered_protocols{$configact{$configact{$module}->{'Port_Up'}}->{'Proto'}}{'modulename'};
		$targetmodule = $configact{$module}->{'Port_Up'};
	}
	$commandparam{'pulsetime'} = $configact{$module}->{'Step_duration'} * $interval;
	$commandparam{'device'} = $configact{$targetmodule}->{'Class'};
	$commandparam{'protocol'} = $configact{$targetmodule}->{'Proto'};
	$commandparam{'busaddress'} = $configact{$targetmodule}->{'Bus_address'};
	$commandparam{'port'} = $configact{$targetmodule}->{'Port_num'};
	$commandparam{'targetstate'} = 'OnPulse';
#																	print "Target Step: $manualstate  Interval ($quidoaddr/$portnum): $interval \n";
	$commandparam{'command'} = 'SetPulse';
	$performedcommand = 'SetPulse';

	if ( $commandparam{'pulsetime'} == 0 ) {
		print "Žádná změna, končím.";
		exit;
	}
	my ($csec,$cmin,$chour,$cmday,$cmon,$cyear,$cwday,$cyday,$cisdst) = localtime (time + $commandparam{'pulsetime'});
	$cyear += 1900;
	$cmon++;
	$configact{$targetmodule}->{'CommandEnd'} = sprintf ("%02d",$cyear) . ':' . sprintf ("%02d", $cmon) . ':' . sprintf ("%02d", $cmday) . ':' . sprintf ("%02d", $chour) . ':' . sprintf ("%02d",$cmin) . ':' . sprintf ("%02d",$csec);
 
#	if (write_curstep ( $module, $manualstate ) == $resetstep ) {
#																	print "Can't write $module actual step ($manualstate) <BR>\n";
#																	print $main::tempfolder . $module . $main::stepsuffix . "<BR>\n";
#	}
	
}
# build command according to %commandparam hash
$evalstring =  '$command' . "= $protocol_module" . "::build_command (";
	foreach my $key ( keys %commandparam ) {
	$evalstring = $evalstring . "$key => '$commandparam{$key}', ";
}
$evalstring = $evalstring . ");";
																		print " >> \n$evalstring\n<<\n";
#																		exit;
eval ( $evalstring );

if ( defined ( $command ) ) {
		print "Příkaz úspěšně sestaven<BR>\n";
		print "===>>\n$command\n<<===<BR>\n";
} else {
	print "Chyba při sestavování příkazu! KONČÍM.";
	exit;
}
# send command		
if ( defined ($configact{$targetmodule}->{'Gateway'}  ) ) {
	$sendresult = send_command2 ( $command, $gwtab{ $configact{$targetmodule}->{'Gateway'} }->{'NetAddress'}, $gwtab{ $configact{$targetmodule}->{'Gateway'} }->{'NetPort'}, \$curstat, $registered_protocols{$configact{$targetmodule}->{'Proto'}}{'continuecallback'});
	$sendresult = send_command2 ( $command, $gwtab{ $configact{$targetmodule}->{'Gateway'} }->{'NetAddress'}, $gwtab{ $configact{$targetmodule}->{'Gateway'} }->{'NetPort'}, \$curstat, $registered_protocols{$configact{$targetmodule}->{'Proto'}}{'continuecallback'});
} else {
	$sendresult = send_command2 ($command, $remote, $port, \$curstat, $registered_protocols{$configact{$targetmodule}->{'Proto'}}{'continuecallback'});
}
unless ($sendresult eq "COM_SUCCESS") {

	print (2, "Odelání příkazu selhalo: $sendresult");
	exit;															
}
print "Příkaz odeslán úspěšně<BR>\n";
#my $curstat = send_command ($command, \$rsconnection);
#$command =  "*B$quidoaddr" . "OR$portnum";
# parse command response

my $responsecode;			
my $curstatptr = \$curstat;
$evalstring = '$responsecode' . " = $protocol_module" . "::translate_response (
										command => '$performedcommand',
										sentcommand => '$command',
										response => '$curstat',
										protocol => '$configact{$targetmodule}->{'Proto'}',
										device => '$configact{$targetmodule}->{'Class'}',
										responsedataptr => " . '$curstatptr' . ",
										targetstate => ''
										);";
#																		print "Translate string: $evalstring\n";
eval($evalstring);

		
unless ( $responsecode eq 'PROTO-OK' ) {
	print  "Chyba zpracování příkazu: $module - $responsecode<BR>\n";
	exit;
} else {
	print "<B>Příkaz přijat</B><BR>\n";											
}
# Command accepted -> assume requested value, set CommandEnd	
if ( $manualstate =~ /\d+/ ) {
	
	if (write_curstep ( $module, $manualstate ) == $resetstep ) {
																	print "Can't write $module actual step ($manualstate) <BR>\n";
#																	print $main::tempfolder . $module . $main::stepsuffix . "<BR>\n";
	}
	write_last_states ( \%configact, $stattable, $checktime );
	print "Výsledné hodoty zapsány.<BR>\n";
}

# read final module state
$evalstring = '$command' . " = $protocol_module" . "::build_command (
										command => 'ReadState',
										protocol => '$configact{$targetmodule}->{'Proto'}',
										device => '$configact{$targetmodule}->{'Class'}',
										busaddress => '$configact{$targetmodule}->{'Bus_address'}',
										port => '$configact{$targetmodule}->{'Port_num'}',
										targetstate => '',
										);";
#																		print "Command string:$evalstring\n";
eval ($evalstring);		
unless (defined $command) {
#				$conftbl{ $key } {'CurState'}  = "ERROR:BuildComm";
	print "Chyba při sestavování kontroly výsledného stavu<BR>\n";
	exit;															
}
$performedcommand = 'ReadState';
$curstat = '';
$curstatptr = \$curstat;

if ( defined ($configact{$module}->{'Gateway'}  ) ) {
	$sendresult = send_command2 ( $command, $gwtab{ $configact{$targetmodule}->{'Gateway'} }->{'NetAddress'}, $gwtab{ $configact{$targetmodule}->{'Gateway'} }->{'NetPort'}, \$curstat, $registered_protocols{$configact{$targetmodule}->{'Proto'}}{'continuecallback'});
} else {
	$sendresult = send_command2 ($command, $remote, $port, \$curstat, $registered_protocols{$configact{$targetmodule}->{'Proto'}}{'continuecallback'});
}
unless ($sendresult eq "COM_SUCCESS") {

	print (2, "Odelání kontroly selhalo: $sendresult");
	exit;															
}
$evalstring = '$responsecode' . " = $protocol_module" . "::translate_response (
										command => '$performedcommand',
										sentcommand => '$command',
										response => '$curstat',
										protocol => '$configact{$targetmodule}->{'Proto'}',
										device => '$configact{$targetmodule}->{'Class'}',
										responsedataptr => " . '$curstatptr' . ",
										targetstate => ''
										);";
#																		print "Translate string: $evalstring\n";
eval($evalstring);

#unless (defined $curstat ) {
#	$curstat = "ERROR";
#}
		
unless ( $responsecode eq 'PROTO-OK' ) {
	print  "Chyba zpracování kontroly: $module - $responsecode<BR>\n";
	exit;
}
#$curstat = send_command ($command, \$rsconnection);

#$curstat =~ s/\*B$quidoaddr.//;
print "Výsledný stav: $responsecode \n";

print "\n <P> HOTOVO\n";
exit;
										

#===============================================================================
# Procedures
#===============================================================================

sub writetime
{
	my $etime = shift;
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime ($etime);
	$year += 1900;
	$mon += 1;
	return sprintf ("%04d", $year) . ':' . sprintf ("%02d", $mon) . ':' . sprintf ("%02d", $mday) . ':' . sprintf ("%02d", $hour) . ':' . sprintf ("%02d", $min);	
}


sub get_type
{
	my $configlinesptr = shift;
	my $sectionname = shift;
	
	my $insection = 0;
	foreach my $aline (@$configlinesptr) {
		my $line = $aline;
		$line =~ s/#.*//;
		if ( $line =~ /[^\[]?\[$sectionname\][^\]]?/ ) {
			$insection = 1;
			next;
		}
		if ( $line =~ /[.+]/ ) {
			$insection = 0;
			next;
		}
		if ($insection && $line =~ /Req_state/i ) {
			$line =~ s/.*=(.*)/$1/;
			return $line;
		}
	}
	return undef;
}


sub canonize_active
{
	my $active = shift;
	
	$active =~ s/#.*//;
	$active =~ s/^\s//g;
	$active =~ s/\s$//g;
	
	return $active;
}


# TODO
# global lock to avoid interference with main program
# 





