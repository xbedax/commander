#!/usr/bin/perl

# USAGE - without parameter performs regular I/O driving according to configuration
#		- CLIENTTEST
#		- SERVERTEST
#		- watchdog  ... performs watchdog check
		

# script state -	stepper implementation 
#					strict, warnings
#					spiller implementation
#					config
#					&ref condition, unified condition checking
#					spiller - multiple intervals
#					socket I/O error handling
#					techlog
#					shared subroutines
#					manual state
#					global lock
#					stephumventer
#					module check frequency
#					log interval
#					consolidated curstate format
#					new state table format
#					comparison with last state from stattable
#					communication error handling improved
# v8
#					further improvements of communication error handling
#					member  vs frequency 
#					improved stattable update
#					signal handler
#					reentered socket closing :-(
#					multiple bus support
#					time of last succesful read added to stattable
#					log level for inputs
#					universal command builder
#					dynamic protocol handlers
#					stephumventer logic repaired
#					watchdog implementation
#8.1.3
#					read/write last steps moved to iconfig
#					long running commands solved
#					roll-back step change if mover fails
#					condition checking on ON / OFF output types
# v9				iterative evaluator
#					EXP: condition
#9.0.1				fixed errors in Condition evaluation
#					introduced tech log size limits
#9.0.2				manual_time_from added
#					compare_endtime moved to iconfig.pm library


use Socket;
use IO::Handle;
use File::stat;
use strict;
use Data::Dumper;
use warnings;
use IO::Socket;
use IO::Socket::INET;
use IO::Select;
use Module::Runtime qw(
        $module_name_rx is_module_name check_module_name
        module_notional_filename require_module);
use MIME::Lite;
use Net::SMTPS;


use lib '.';

our %registered_protocols;

use icomm '2.01.00';
use iconfig '1.03.04';
use iconfig qw (get_curstep write_curstep read_last_states write_last_states compare_endtime);

my $args = join ('', @ARGV);

our %conftbl = ();
my  %configtab = ();
our %gwtab = ();
my %watchdogtab = ();
my $defconfigtable = "./conftable.def";
my $mainconfig = "./config.local";
my $filehandle;
my $mastercounter = 1;
our $version = 9.0.1;
our $stopevent;
our @statequeue;
our @commandqueue;

sub signal_handler {
	my $Signal = shift;
	my $MyIdent = "";

																		printlog (1, "!!!- Caught a signal $Signal -!!!");
	if ($Signal eq 'HUP') {
																		printlog (1, "... trying to ignore ...");
		return;
	}

																		printlog (1, "... trying to close all sockets");

	initer::close_all();
																		printlog (1, "Exiting.");
	exit;
}
		
#use sigtrap 'handler' => \&signal_handler, 'signal';

$SIG{TERM} = \&signal_handler;
$SIG{INT} = \&signal_handler;
if ( $^O eq 'MSWin32' ) {
	$SIG{BREAK} = \&signal_handler;
}
$SIG{QUIT} = \&signal_handler;
$SIG{HUP} = \&signal_handler;

if ( -r $mainconfig) {
	open ($filehandle, "$mainconfig") || die "INITER: Can't open $mainconfig: $!\n";
} else {
	die "INITER: Can't find $mainconfig!\n";
}

read_config ($filehandle, \%configtab);
close ($filehandle);



my $TESTING = $configtab{'Global'}->{'TESTING'};
my $configtable = $configtab{'Global'}->{'ConfigTable'};
my $logtable = $configtab{'Global'}->{'LogTable'};
our $logto = $configtab{"log"}->{"logto"};
our $loglevel = $configtab{"log"}->{"level"};
our $logfile = $configtab{"log"}->{"file"};
my $stattable = $configtab{'Global'}->{'StatTable'};
our $tempfolder = $configtab{'Global'}->{'TempFolder'};
our $stepsuffix = $configtab{'Stepper'}->{'StepSuffix'};
my $lockfile = $configtab{"Global"}->{"Lockfile"};
my $maxruntime = $configtab{"Global"}->{"Maxruntime"};
our $resetstep = $configtab{'Stepper'}->{'ResetStep'};
my $watchdogtable = $configtab{'Watchdog'}->{'WatchdogFile'};

our $remote = $configtab{'RSGW'}->{'NetAddress'};										# tohle do podminky, neni povinne
our $port = $configtab{'RSGW'}->{'NetPort'}; 

our $maxtotallogsize = $configtab{'log'}->{'MaxTotalLogSize'}; 
our $maxrunlogsize = $configtab{'log'}->{'MaxRunLogSize'}; 

my $gwfile = $configtab{'Comm'}->{'GatewayTable'};
my $unixtime = time;
our ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime ($unixtime);
my $locmins = 60 * $hour + $min;
$year += 1900;
$mon += 1;
our $loglocal = 1;


#-------------------------------- test evaluate_condition
#my $level = 0;
#evaluate_condition ( $args, $level );
#exit;

#--------------------------------


my $watchdogserver = $configtab{'Watchdog'}->{'AlertServer'};
my $watchdogserverssl = $configtab{"Watchdog"}->{"AlertSsl"};
my $watchdogserversslversion = $configtab{"Watchdog"}->{"AlertSslVersion"};
my $watchdogserverport = $configtab{"Watchdog"}->{"AlertPort"};
my $watchdoguser = $configtab{"Watchdog"}->{"AlertUser"};
my $watchdogpassword = $configtab{"Watchdog"}->{"AlertPassword"};
my $watchdogalerttype = $configtab{"Watchdog"}->{"Alerttype"};
my $watchdogaddressee = $configtab{"Watchdog"}->{"Addressee"};
my $watchdogsubject = $configtab{"Watchdog"}->{"Subject"};

if ( $args =~ /watchdog/i ){
	
	if (open ($filehandle, "$stattable") ) {
		load_last_states ($filehandle, \%conftbl);
		close $filehandle;
	}
	if (open ($filehandle, "$watchdogtable") ) {
		read_config ($filehandle, \%watchdogtab);
		close $filehandle;
	}
	watchdog_check ( );
	exit;
}


unless ( defined $TESTING ) {
	$TESTING='NO';
}
unless ( $tempfolder =~ /\/$/ ) {
	$tempfolder = $tempfolder . "/";
}
																		printlog (1, "======= Starting $mday.$mon.$year - $hour.$min:$sec (version $version) ========");
my $openresult = opendir (DIR, './protocols') or do {
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
																		
foreach my $prot (keys %registered_protocols){
																		printlog (4, "Protocol $prot -> " . $registered_protocols{$prot}{'modulename'} . " registered.");
}

if ( -r $gwfile) {
	open ($filehandle, "$gwfile") || die "INITER: Can't open $filehandle: $!\n";
} else {
	die "INITER: Can't find $filehandle!\n";
}

read_config ($filehandle, \%gwtab);
close ($filehandle);

use if  $^O eq 'MSWin32' , "Win32::Event";
use if  $^O eq 'MSWin32' , "threads";
use if  $^O eq 'MSWin32' , "threads::shared";

my $parentpid = $$;
my $parentgid = 0;
if ( $^O ne 'MSWin32' ) {
	$parentgid = getpgrp ();
}

my $prevpid;
my $prevgid;
my $prevmastercounter;

$mastercounter++;
#-------------lock file testing --------------------

if (-e $lockfile) {
	if ($maxruntime == 0) {
																		printlog (1, "Initer $version exiting - previous task still running (unlimited)");
		exit;
	}
	my $sb = stat($lockfile);
	my $mdate = $sb->mtime;
	if ((time - $mdate)  < $maxruntime) {								printlog (1, "Initer $version exiting - previous task still running");
		exit;
	}
	open ( IHC, "$lockfile" );
	while  ( <IHC> ) {
		if (/pid:(.*)/) {
			$prevpid = $1;
		}
		if (/ctr:(.*)/) {
			$prevmastercounter = $1;
		}
		if (/gid:(.*)/) {
			$prevgid = $1;
		}
	}
																	
	close IHC;
																		
	if ( $^O eq 'MSWin32' ) {
																		printlog (1, "Removing previous initer instance $prevpid");
		my $serverstopevent = Win32::Event->open('IroomInitEvent');
		if (defined ($serverstopevent)) {
			print "Event found\n";
			$serverstopevent->set();
		}
		
#zkusit udelat thread - cekat na pojmenovany event, druhy thread zaregistruje event ahndlet na INT, kdyz prijde event, poslat sam sobe INT, cleanup, pobit thready a zavalit ... mozna


#		tohle nefunguje na Win32 a asni ani na MacOs
#		print "Killing $prevpid\n";
#		print my $res = kill (2, $prevpid);
#		print $^E;
		
		
#		tohle odpovida kill -9 ... bez moznosti obslouzeni		
#																		printlog (1, "... $res");
#		`taskkill /t /F /pid $prevpid`;

#		funguje pouze na procesy na stejne consoli (kterej idiot to naprogramoval?)		
#		use Win32::Console qw( CTRL_BREAK_EVENT );
#		print "Killing $prevpid " . Win32::Console->GenerateCtrlEvent(CTRL_BREAK_EVENT, $prevpid) . "\n";
		

#------------- zabije, ale nejde obslouzit
#		use Win32API::Process ':All';
#		my $proch = Win32API::Process::OpenProcess (PROCESS_TERMINATE, 0, $prevpid);
#		print "Removing $prevpid / $proch\n";
#		Win32API::Process::TerminateProcess($proch, -1);


#------------- tohle je dobry - zabije tree		
		# require 'Win32/Process/Info.pm';
		# require 'Win32/Process.pm';

		# Win32::Process::Info->import();

		# my $pi = Win32::Process::Info->new('', 'WMI');
		# my $iters;

		# while (my %info = $pi->Subprocesses($prevpid)) {
			# if (++$iters > 40) {
				# Win32::Process::TerminateProcess($prevpid, -1);
				# return 'Aborting';
			# }

			# my @leaves = grep {!@{$info{$_}}} keys %info;

			# last if !@leaves;

			# print "Killing	: @leaves\n";
			# Win32::Process::KillProcess($_, -1) for @leaves;
			# sleep 2;    # Allow a little time for processes to die
		# }
#----------
	} else {
																		printlog (1, "Removing previous initer instance $prevgid");
	kill 'TERM', $prevgid; 
	}
#	unlink $lockfile;
}

if ( $args =~ /CLIENTTEST/  ) {
	exit;
}


#-------- write lock file
open ( OHC, '>', "$lockfile" );
print OHC "pid:$$\ngid:$parentgid\nctr:$mastercounter\n";
close OHC;
#print  "pid:$$\ngid:$parentgid\nctr:$mastercounter\n";
#while (1) {print "."; sleep (5);};			
#exit;

																		printlog (2, "config: $configtable");
if ( -r $configtable) {
																		printlog (3, "Primary config used!");
	open ($filehandle, "$configtable") || do { 							printlog (1, "INITER: Can't open $configtable: $!");
												exit;
											}
} else {
																		printlog (3, "Secondary config used!");
	open ($filehandle, "$defconfigtable") || do { 						printlog (1, "INITER: Can't open $defconfigtable: $!");
													exit;
												}
}

read_config ($filehandle, \%conftbl);
close ($filehandle);


if (open ($filehandle, "$stattable") ) {
	read_last_states ($filehandle, \%conftbl);
	close $filehandle;
}else{
																		printlog (1, "INITER: Can't open $stattable: $!");
	foreach my $key (keys %conftbl) {
		$conftbl{$key}{'LastState'} = 'N/A';
	}
												
}

if ( $args =~ /watchdog/i ){
	my %WDParam;

		watchdog_check ( );
	exit;
}


if ( $args =~ /SERVERTEST/  ) {
	my $fullstop :shared = 0;

	sub event_watchdog
	{
		$stopevent->wait();
		print "Stopevent occured'n";
		if ($fullstop) {
			return;
		} else {
			exit();
		}
		
	}
				
		$stopevent = Win32::Event->new(0, 0, 'IroomInitEvent');
		
		my $ewd = threads->new( \&event_watchdog );
		print "Server running:\n";
		$|=1;
		for (1..10) {
			print '.';
			sleep 5;
		}
		$fullstop = 1;
		$stopevent->set();
		$ewd->join ();
		exit();
}

#-----------------------------------------------
# process config table - read current states
#-----------------------------------------------

set_param(
					commandretry => 2,
					commandpause => 1,
					commandtimeout => 1,
					connectiontimeout => 1,
					connectionpause => 2,
					connectionretry => 1,
				);

if ($TESTING eq 'YES') {
																		printlog (3, "Config READ:");
}
foreach  my $key (keys %conftbl) {
	push (@statequeue, $key);
																		printlog (4, "$key :");
																		printlog (4, "Readclass: " . $conftbl{$key}->{'Class'}) ;
	my $command;
	my $quidoaddr;
	my $portnum;
	my $gateway;
	my $curstat = "";
	my $evalstring;
	my $protocol_module;
	my $sendresult;
	
	if ($conftbl{$key}->{'Class'} =~ /Qport/ || $conftbl{$key}->{'Class'} =~ /Qterm/  || $conftbl{$key}->{'Class'} =~ /Qinpt/) { 
		$portnum = $conftbl{$key}->{'Port_num'};
	}
	if ($conftbl{$key}->{'Class'} =~ /Qpair/ ) {
		$quidoaddr = 0;
	} else {
		$quidoaddr = $conftbl{$key}->{'Bus_address'};
		$gateway = $conftbl{$key}->{'Gateway'};
	}

	if ($conftbl{$key}->{'Class'} =~ /Qpair/ ) { 
																		printlog (4, "Qpair:	*B$quidoaddr" . "... $key");
		$conftbl{ $key } {'CurState'}  =  'Step:' . get_curstep ( $key );
		next;
	}
	unless ( defined $conftbl{ $key }{'Port_num'} ) {
		$conftbl{ $key }{'Port_num'} = 0;
	}

	$protocol_module = $registered_protocols{$conftbl{$key}->{'Proto'}}{'modulename'};

	undef $command;
	my $targetstate = '';
	if (defined $conftbl{$key}{'Clear_read'}) {
		if ( $conftbl{$key}{'Clear_read'} eq 'YES' ) {
			$targetstate = 'Clear';
		} else {
			$targetstate = 'NoClear';
		}
	}
	$evalstring = '$command' . " = $protocol_module" . "::build_command (
											command => 'ReadState',
											protocol => '$conftbl{$key}->{'Proto'}',
											device => '$conftbl{$key}->{'Class'}',
											busaddress => '$conftbl{$key}->{'Bus_address'}',
											port => '$conftbl{$key}->{'Port_num'}',
											targetstate => '$targetstate',
											);";
#																		print "Command string:$evalstring\n";
	eval ($evalstring);
																		
	unless (defined $command) {
		$conftbl{ $key } {'CurState'}  = "ERROR:BuildComm";
																		printlog (2, "Building command failed");
		next;															
	}
	if ( defined ($conftbl{$key}->{'Gateway'}  ) ) {
		$sendresult = send_command2 ( $command, $gwtab{ $conftbl{$key}->{'Gateway'} }->{'NetAddress'}, $gwtab{ $conftbl{$key}->{'Gateway'} }->{'NetPort'}, \$curstat, $registered_protocols{$conftbl{$key}->{'Proto'}}{'continuecallback'});
	} else {
		$sendresult = send_command2 ($command, $remote, $port, \$curstat, $registered_protocols{$conftbl{$key}->{'Proto'}}{'continuecallback'});
	}
	unless ($sendresult eq "COM_SUCCESS") {
		$conftbl{ $key } {'CurState'} = "ERROR:$sendresult";
																		printlog (2, "Reading state communication failed $sendresult");
		next;															
	}
																		printlog (5, " Data read: $curstat");
#																		my @responsearray = split ('', $curstat );
#																		foreach my $resppart (@responsearray ) {
#																			print sprintf ("%02X", ord($resppart)).' ';
#																		}
#																		print "\n";

	my $responsecode;
	my $curstatptr = \$curstat;
	my $componentpart = '';
	if ( defined $conftbl{$key}{'Component'} ) {
		$componentpart = 'component => ' . "'" . $conftbl{$key}{'Component'} . "',";
	}
	$evalstring = '$responsecode' . " = $protocol_module" . "::translate_response (
											command => 'ReadState',
											sentcommand => '$command',
											response => '$curstat',
											protocol => '$conftbl{$key}->{'Proto'}',
											device => '$conftbl{$key}->{'Class'}',
											responsedataptr => " . '$curstatptr' . ",
											targetstate => '',
											$componentpart
											);";
#																		print "Response string: $evalstring\n";
	eval($evalstring);

	# $responsecode   = proto_serial::translate_response (
											# command => 'ReadState',
											# response => $curstat,
											# protocol => $conftbl{$key}->{'Proto'},
											# device => $conftbl{$key}->{'Class'},
											# responsedataptr => $curstatptr,
											# targetstate => ''
											# );
		

	unless (defined $responsecode) {
		$conftbl{ $key } {'CurState'}  = "ERROR:TranslateResp";
																		printlog (2, "Translating response failed");
		next;															
	}
		
#																		printlog (4, "	Statut read:	$responsecode");
	unless ($responsecode eq "PROTO-OK") {
		$conftbl{ $key } {'CurState'} = "ERROR:$responsecode";
																		printlog (2, "Reading state failed $responsecode");
		next;															
	}
	if ( defined ( $conftbl{ $key } {'Component'} ) ) {
		my $component = $conftbl{ $key } {'Component'};
		$curstat =~ s/.*($component\s*:\s*[^;]+).*/$1/;
	}
	$conftbl{ $key } {'CurState'}  = $curstat;
#																		print "Reading state final: $curstat  /" . $curstatptr . "\n";

} 

#-----------------------------------------------
# process config table - derive required states
#-----------------------------------------------
																		printlog (3, "Computing required states");
my $changes = "";
my $QueueLength = scalar @statequeue;
my $LastQueueLength = $QueueLength;

while (my $key = shift @statequeue ) {

	my $setstate;
	my $newstate;
	my $portnum;
	my $quidoaddr;
	my $evaluation;

	$QueueLength--;
																		printlog (4, " $key :  (q: $QueueLength)");	
																		printlog (4, "     CurState: " . $conftbl{ $key } {'CurState'} );
	if ( $QueueLength < 1 ) {
		$QueueLength = scalar @statequeue;
		unless ( $QueueLength < $LastQueueLength ) {
			my $keysleft = $key;
			$conftbl{$key}{'NewState'} = $conftbl{$key}{'Default_state'};
			foreach my $lkey ( @statequeue ) {
				$conftbl{$lkey}{'NewState'} = $conftbl{$lkey}{'Default_state'};
				$keysleft = $keysleft . ", $lkey";
			}
			$keysleft =~ s/^,\s*//;
																		printlog (1, "ERROR: Can not establish NewState for $keysleft. Perhaps a circular reference in conditions. Reverting to DEFAULT_STATE." );
			last;
		}
		$LastQueueLength = $QueueLength;
	}
	if ( defined ( $conftbl{$key}->{'Req_state'} ) ) {
																		printlog (4, "     ReqState= $conftbl{$key}->{'Req_state'}");
	}

# if curtime is not multiply of Frequency parameter, do nothing
	if ( defined $conftbl{$key}->{'Frequency'} ) {
		if ( $locmins % $conftbl{$key}->{'Frequency'} ) {
																		printlog (5, "Skipping $key ... not a time to run control");
			$conftbl{$key}->{'NewState'} = read_curstate ( $key );
			next;
		}
	}

# Manual state active => do not change anything
	if ( defined ($conftbl{$key}->{'Manual_state'} ) ) {
																		printlog ( 5, "Manual state check: $key" );			
#																		printlog ( 5, ' From:' . $conftbl{$key}->{'Manual_time_from'} . ' To:'  . $conftbl{$key}->{'Manual_time_to'} . ' Check:' . localtime( time()-59 ) );
		if ( compare_endtime ( $conftbl{$key}->{'Manual_time_to'} ) ) {
			unless ( (defined ( $conftbl{$key}->{'Manual_time_from'} ) ) && ( compare_endtime ($conftbl{$key}->{'Manual_time_from'}, time() ) ) ) {
				$newstate = $conftbl{$key}->{'Manual_state'};
																		printlog ( 5, "  - manual state $newstate active" );
				if ( $newstate =~ /State\s*:\s*ON/ ) {
					$conftbl{$key}{'NewState'} = 'ON';
				}elsif ( $newstate =~ /State\s*:\s*OFF/ ) {
					$conftbl{$key}{'NewState'} = 'OFF';
				}else{
					my $DeltaStep = $newstate - read_curstate( $key );
					if ( $DeltaStep < 0 ) {
						$conftbl{$conftbl{$key}{'Port_Down'}}{'NewState'} = 'INT:' . $DeltaStep * $conftbl{$key}{'Step_duration'} * -1;
					}
					if ( $DeltaStep > 0 ) {
						$conftbl{$conftbl{$key}{'Port_Up'}}{'NewState'} = 'INT:' . $DeltaStep * $conftbl{$key}{'Step_duration'} * -1;
					}
																		printlog ( 5, "  - delta: $DeltaStep " );
					$conftbl{$key}{'NewState'} = $newstate;
				}
				next;
			}
		}
	}

	if ( ($conftbl{$key}->{'Class'} =~ /Qport/) ) { 

		$setstate = $conftbl{$key}->{'Req_state'};
		$newstate = $conftbl{$key}->{'Default_state'};
		$portnum = $conftbl{$key}->{'Port_num'};
		$quidoaddr = $conftbl{$key}->{'RS_address'};


# QPmember type output
# ... is controlled via superior control structure
# ... does not compute new state by its own
# ... even non-controllable by manual settings
		if ($setstate =~ /member/) {
			unless ( defined ( $conftbl{$key}->{'NewState'} ) ) {
				$conftbl{$key}->{'NewState'} = 'NOOP';					#Necessary to handle QPair Frequency parameter
			}
			next;
		}
		
# ON type output
# ... permanently on
# ... if the condition is met
		if ($setstate eq 'ON') {
			$evaluation = evaluate_condition ($conftbl{$key}->{'Condition'}, 0);
			if ( $evaluation == 0 ){
				$newstate = 'OFF';
			} elsif ( $evaluation == 1 ){
				$newstate = 'ON';
			} else {													#Not determined
				push (@statequeue, $key );
				next;
			}
		}
# OFF type output
# ... permanently off
# ... if the condition is met
		if ($setstate eq 'OFF') {
			$evaluation = evaluate_condition ($conftbl{$key}->{'Condition'}, 0);
			if ( $evaluation == 0 ){
				$newstate = 'ON';
			} elsif ( $evaluation == 1 ){
				$newstate = 'OFF';
			} else {													#Not determined
				push (@statequeue, $key );
				next;
			}
		}
#
# TIMEer type output
# ... switched on iff current time is between State_from and State_to and conditions are met
# ... alternatively iff current time is inside one of intervals hhmm-hhmm  separated by "," as specified in State_on_int
# ... switches off otherwise
		if (($setstate eq 'TIME') || ($setstate eq 'TIMEI' )) {
			my $timefrom;
			my $timeto;

			if ($setstate eq 'TIME' ) {
				$timefrom = $conftbl{$key}->{'State_from'};
				$timeto = $conftbl{$key}->{'State_to'};
				$newstate = evaluatetimes ( $timefrom, $timeto, $locmins )
			} else {
				my @intervals = split /,/, $conftbl{$key}->{'State_on_int'};
				$newstate = 'OFF';
				foreach my $interval (@intervals) {
					$timefrom = $interval;
					$timefrom =~ s/(.*)-.*/$1/;
					$timeto = $interval;
					$timeto =~ s/.*-(.*)/$1/;
#																		print "$timefrom - $timeto \n";
					if (evaluatetimes ( $timefrom, $timeto, $locmins ) eq 'ON') {
						$newstate = 'ON';
					}
				}
			}
#																		print "     yday: $yday \n";
			$evaluation = evaluate_condition ($conftbl{$key}->{'Condition'}, 0);
			if ( $evaluation == -1 ){
				push (@statequeue, $key );
				next;
			} elsif ( $evaluation == 0 ){
				$newstate = 'OFF';
			}
		}

# SPILLer type output
# ... starts spilling iff meter is ON && time is between State_from and State_to 
# ... performs pulses M minutes long, each two separated by N minutes pause
		if ($setstate eq 'SPILL' ) {
			my $meter = $conftbl{$key}->{'Meter'};
			my $spilllen = $conftbl{$key}->{'Spill_len'};
			my $spillpause = $conftbl{$key}->{'Spill_pause'};
			my $lvl = read_curstate ( $meter );
			my $llocmins;
			chomp $lvl;
			my @intervals = split /,/, $conftbl{$key}->{'State_on_int'};
			$newstate = 'OFF';

			foreach my $interval (@intervals) {
				my $timefrom = $interval;
				$timefrom =~ s/(.*)-.*/$1/;
				my $timeto = $interval;
				$timeto =~ s/.*-(.*)/$1/;
				if (($lvl =~ /ON/) && (evaluatetimes ( $timefrom, $timeto, $locmins ) eq 'ON')) {
					my $frommins = (60 * int($timefrom / 100)) + ($timefrom % 100);
					if ($frommins > $locmins) {
						$llocmins = $locmins + 24 * 60 - $frommins;
					}else{
						$llocmins = $locmins - $frommins;
					}
					if(($llocmins % ($spilllen + $spillpause)) < $spilllen) {
						$newstate = 'ON';
						last;
					}
				}
			}
			$evaluation = evaluate_condition ($conftbl{$key}->{'Condition'}, 0);
			if ( $evaluation == 0 ){
				$newstate = 'OFF';
			} elsif ( $evaluation == -1 ){							#Not determined
				push (@statequeue, $key );
				next;
			}
		}
		
# HEATer type output
# ... switches on iff measured temperature is bellow Temp_min
# ... switches off iff output in on and measrued temperature is above Temp_min + Temp_hyst

		if ($setstate eq 'HEAT') {

			my $meter = $conftbl{$key}->{'Meter'};
			my $treshtemp = $conftbl{$key}->{'Temp_min'};
			my $hystetemp = $conftbl{$key}->{'Temp_hyst'};
			my $tmpr = read_curstate ( $meter );
			if ($tmpr =~ /ERROR/) {$newstate = $conftbl{$key}->{'Default_state'};
				next;
			}
			$tmpr =~ s/Term: ([^\s]*).*/$1/;
			if ( $tmpr < $treshtemp ) {$newstate = 'ON';};
			if ( $tmpr > $treshtemp + $hystetemp ) {$newstate = 'OFF';};
			$evaluation = evaluate_condition ($conftbl{$key}->{'Condition'}, 0);
			if ( $evaluation == 0 ){
				$newstate = 'OFF';
			} elsif ( $evaluation == -1 ){							#Not determined
				push (@statequeue, $key );
				next;
			}
		}

		

# PULSE type output
# ... if condition is met, output is switched on at State_from time
# ... if switched on, output is switched off at State_to time
# ... no conditions checking during the pulse period

		if ($setstate eq 'PULSE') {

			my $meter = $conftbl{$key}->{'Condition'};
			$meter =~ s/.*\&//;
			$meter =~ s/:.*//;
			my $meterstate = read_curstate ( $meter );

			my $timefrom = $conftbl{$key}->{'State_from'};
			my $timeto = $conftbl{$key}->{'State_to'};
			my $frommins = (60 * int($timefrom / 100)) + ($timefrom % 100);
			my $tomins = (60 * int($timeto / 100)) + ($timeto % 100);
#																		print "     times: from=$frommins to=$tomins cur=$locmins\n";
			if ($frommins <= $tomins) {
				if ($frommins <= $locmins && $tomins > $locmins && $meterstate eq 'OFF') {
					$newstate = 'ON';
				} 
				if ($tomins <= $locmins || $frommins > $locmins) {
					$newstate = 'OFF';
				} 
			} else {
				if (($frommins <= $locmins || $tomins > $locmins) && $meterstate eq 'OFF') {
					$newstate = 'ON';
				} 
				if ($locmins >= $tomins && $locmins < $frommins) {
					$newstate = 'OFF';
				}
			}
			$evaluation = evaluate_condition ($conftbl{$key}->{'Condition'}, 0);
			if ( $evaluation == 0 ){
				$newstate = 'OFF';
			} elsif ( $evaluation == -1 ){							#Not determined
				push (@statequeue, $key );
				next;
			}
		}

	
		$conftbl{$key}{'NewState'} = $newstate;	
	}

	if ( $conftbl{$key}->{'Class'} =~ /Qpair/ ) { 
# STEPVENTer type output
# ... if  Temp_max is exceeded, opens vent one step more ... until max steps is reached
# ... if the metered temperature is bellow Temp_max - Temp_hyst, closes vent one step less until step zero is reached
# ... if the cur_step value is not available, resets vent to closed position and sets cur_step = 0
#							print "Computing $key:\n";
		my $setstate = $conftbl{$key}->{'Req_state'};
							
		if ($setstate eq 'STEPVENT') {
				
			my $meter = $conftbl{$key}->{'Meter'};
			my $treshtemp = $conftbl{$key}->{'Temp_max'};
			my $hystetemp = $conftbl{$key}->{'Temp_hyst'};
			my $stepnum = $conftbl{$key}->{'Step_count'};
			my $stepduration = $conftbl{$key}->{'Step_duration'};
			my $stepfile = $tempfolder.$key.$stepsuffix;
			my $curstep = get_curstep ( $key );
			my $moverupstate = read_curstate ( $conftbl{$key}->{'Port_Up'} );
			my $moverdownstate = read_curstate ( $conftbl{$key}->{'Port_Down'} );
			my $tmpr = read_curstate ( $meter, 'Term' );
			my $commandlength;
			my $targetmodule;
			if ($tmpr =~ /ERROR/) { next; };
#			$tmpr =~ s/Term: ([^\s]*).*/$1/;

#	wait if previous command is still running
			if ( is_running ( $conftbl{$key}->{'Port_Up'} ) || is_running ( $conftbl{$key}->{'Port_Down'} ) ) {
				$conftbl{$key}->{'NewState'} = $conftbl{$key}->{'CurState'};
				next;
			}

			$conftbl{$conftbl{$key}->{'Port_Up'}}->{'NewState'} = "OFF";
			$conftbl{$conftbl{$key}->{'Port_Down'}}->{'NewState'} = "OFF";
			if ( defined $conftbl{$key}->{'Frequency'} ) {
				if ( $locmins % $conftbl{$key}->{'Frequency'} ) {
																		printlog (5, "Skipping $key ... not a time to run control");
					$conftbl{$key}->{'NewState'} = $conftbl{$key}->{'CurState'};
					next;
				}
			}
																		printlog (3, "Processing $key: ... $curstep ");
			if ($curstep == $resetstep ) { 
				$commandlength = $stepduration * $stepnum;
				$targetmodule = $conftbl{$key}->{'Port_Down'};
				$conftbl{$targetmodule}{'NewState'} = "INT:$commandlength";
				$conftbl{$targetmodule}{'Requester'} = $key;
																		printlog (3, "Resetting $key: ... INT:$commandlength ");				
				write_curstep ($key, 0);
				$conftbl{$key}{'NewState'} = 0;
#																		print  "$key : RESET $stdur \n";
			} elsif ( $curstep > $stepnum  ) {
				$targetmodule = $conftbl{$key}->{'Port_Down'};
				$commandlength = $stepduration * ($curstep - $stepnum);
				$conftbl{$targetmodule}->{'NewState'} = "INT:$commandlength";
				$conftbl{$targetmodule}{'Requester'} = $key;
				write_curstep ($key, $stepnum);
				$conftbl{$key}{'NewState'} = $stepnum;
						
			} else {
				if ( ($tmpr > $treshtemp) && ($curstep < $stepnum)) {
					$targetmodule = 	$conftbl{$key}->{'Port_Up'};
					$conftbl{$targetmodule}->{'NewState'} = "INT:$stepduration";
					$curstep++;
					$commandlength = $stepduration;
					$conftbl{$targetmodule}{'Requester'} = $key;
					write_curstep ($key, $curstep);
					$conftbl{$key}{'NewState'} = $stepnum;
#																		print  "$key operation : UP $stepduration \n";
				}
				
				if ( ($tmpr < $treshtemp - $hystetemp) && ($curstep > 0)) {
					$targetmodule = $conftbl{$key}->{'Port_Down'};
					$conftbl{$targetmodule}->{'NewState'} = "INT:$stepduration";
					$curstep--;
					$commandlength = $stepduration;
					$conftbl{$targetmodule}{'Requester'} = $key;
					write_curstep ($key, $curstep);
					$conftbl{$key}{'NewState'} = $stepnum;
#																		print  "$key operation : DOWN $stepduration \n";
				}
			}
		}
#		
		if ($setstate eq 'STEPHUMVENT') {
# STEPHUMVENT type output
# ... temperature control same as stepventer
# ... plus:
# ... independent humidity control allows open vents even in lover temperatures
# ... sets absolute minimum temperature bellow which the vents are closed in any case
				
 			my $tmeter = $conftbl{$key}->{'Tmeter'};
			my $hmeter = $conftbl{$key}->{'Hmeter'};
			my $treshtemp = $conftbl{$key}->{'Temp_max'};
			my $hystetemp = $conftbl{$key}->{'Temp_hyst'};
			my $treshhum = $conftbl{$key}->{'Hum_max'};
			my $hystehum = $conftbl{$key}->{'Hum_hyst'};
			my $hventmintemp = $conftbl {$key}->{'Hvent_mintemp'};
			my $stepnum = $conftbl{$key}->{'Step_count'};
			my $stepduration = $conftbl{$key}->{'Step_duration'};
			my $stepfile = $tempfolder.$key.$stepsuffix;
			my $curstep = read_curstate ( $key );							# tady by melo stacit read_curstep ( $key )
			my $moverupstate = read_curstate ( $conftbl{$key}->{'Port_Up'} );
			my $moverdownstate = read_curstate ( $conftbl{$key}->{'Port_Down'} );
			my $tmpr = read_curstate ( $tmeter, 'Term' );
			my $humi = read_curstate ( $hmeter, 'Hum' );
			my $commandlength;
			my $targetmodule;

#			$tmpr =~ s/.*Term:([^\s]*).*/$1/;
#			$humi =~ s/.*Hum:([^\s]*).*/$1/;

																		printlog (5, "Meassured: $tmpr Max: $conftbl{$key}->{'Temp_max'} Hyst: $conftbl{$key}->{'Temp_hyst'} Min: $hventmintemp");
																		printlog (5, "Meassured: $humi Max: $conftbl{$key}->{'Hum_max'} Hyst: $conftbl{$key}->{'Hum_hyst'}");
																		printlog (5, "CurStep  : $curstep");
#																		print "     Tmpr  : $tmpr \n";
#																		print "     Tresh : $treshtemp \n";
#																		print "	    Dura  : $stepduration \n";
#																		print "	    Scount: $stepnum\n";
#	wait if previous command is still running
			if ( is_running ( $conftbl{$key}->{'Port_Up'} ) || is_running ( $conftbl{$key}->{'Port_Down'} ) ) {
				$conftbl{$key}->{'NewState'} = $conftbl{$key}->{'CurState'};
				next;
			}
			$conftbl{$conftbl{$key}->{'Port_Up'}}->{'NewState'} = "OFF";
			$conftbl{$conftbl{$key}->{'Port_Down'}}->{'NewState'} = "OFF";
			if (  defined $conftbl{$key}->{'Frequency'}  ) {
				if ( $locmins % $conftbl{$key}->{'Frequency'} ) {
																		printlog (4, "Skipping $key ... not a time to run control");
					$conftbl{$key}->{'NewState'} = $conftbl{$key}->{'CurState'};
					next;
				}
			}
#																		printlog (3, "($resetstep)Processing $key: ... $curstep ");
			if ($curstep == $resetstep ) { 
				$commandlength = $stepduration * $stepnum;
				$targetmodule = $conftbl{$key}->{'Port_Down'};
				$conftbl{$targetmodule}{'NewState'} = "INT:$commandlength";
				$conftbl{$targetmodule}{'Requester'} = $key;
																		printlog (4, "Resetting $key: ... INT:$commandlength ");				
				write_curstep ($key, 0);
				$conftbl{$key}{'NewState'} = 0;
#																		print  "$key : RESET $commandlength \n";
			} elsif ( $curstep > $stepnum  ) {
				$commandlength = $stepduration * ($curstep - $stepnum);
				$targetmodule = $conftbl{$key}->{'Port_Down'};
				$conftbl{$targetmodule}->{'NewState'} = "INT:$commandlength";
				$conftbl{$targetmodule}{'Requester'} = $key;
				write_curstep ($key, $stepnum);
				$conftbl{$key}{'NewState'} = $stepnum;
																		printlog (4, "Moving $key back to working range: ... INT:$commandlength");
			} else {
				if ( (($tmpr > $treshtemp) || (($tmpr > $hventmintemp ) && ($humi > $treshhum)))&& ($curstep < $stepnum)) {
					$targetmodule = $conftbl{$key}->{'Port_Up'};
					if ((read_curstate ($conftbl{$key}->{'Port_Down'}) =~ /OFF/ )&& (read_curstate ($conftbl{$key}->{'Port_Up'}) =~ /OFF/)) {
						$conftbl{$targetmodule}->{'NewState'} = "INT:$stepduration";
						$curstep++;
						$commandlength = $stepduration;
						$conftbl{$targetmodule}{'Requester'} = $key;
						write_curstep ($key, $curstep);
						$conftbl{$key}{'NewState'} = $stepnum;
																		printlog (4, "$key operation : UP $stepduration");
					}
				}
				if ( ( ($tmpr < $hventmintemp ) || (($tmpr < $treshtemp - $hystetemp) && ($humi < $treshhum - $hystehum)))&& ($curstep > 0)) {
					$targetmodule = $conftbl{$key}->{'Port_Down'};
					if ((read_curstate ($conftbl{$key}->{'Port_Down'}) =~ /OFF/ )&& (read_curstate ($conftbl{$key}->{'Port_Up'}) =~ /OFF/)) {
						$conftbl{$targetmodule}->{'NewState'} = "INT:$stepduration";
						$curstep--;
						$commandlength = $stepduration;
						$conftbl{$targetmodule}{'Requester'} = $key;
						write_curstep ($key, $curstep);
						$conftbl{$key}{'NewState'} = $stepnum;
																		printlog  (4, "$key operation : DOWN  $stepduration");
					}
				}
			}
		}
	}
}
	
#--------------------------------------
# issue necessary commands 
#--------------------------------------

#my $changes = '';

foreach  my $key (keys %conftbl) {

#																		print " $key >> $conftbl{$key}->{'CurState'} >>>>>> " . read_curstate ( $key ) . "\n";

#get current status
	if ($conftbl{$key}->{'Class'} ne "Qport") {
		next;
	}
# still running last command?
	if ( defined $conftbl{$key}->{'CommandEnd'} ) {
		if ($conftbl{$key}->{'CommandEnd'} gt sprintf ("%02d",$year) . ':' . sprintf ("%02d", $mon) . ':' . sprintf ("%02d", $mday) . ':' . sprintf ("%02d", $hour) . ':' . sprintf ("%02d",$min) . ':' . sprintf ("%02d",$sec)) {
			next;
		}
	}
	my $curstate = 	read_curstate ( $key );
	my $newstate = $conftbl{$key}->{'NewState'};
	my $performedcommand = "";
	my $command;
	my $changefound = 0;
	my $timetoset;
																		printlog (3, "Processing $key: $curstate ... $newstate done ");
	my $protocol_module = $registered_protocols{$conftbl{$key}->{'Proto'}}{'modulename'};
																				
# flip ON / OFF setting if needed
	
	if ($curstate =~ /\s*OFF\s*/ && $newstate =~ /INT:/){
		$changefound = 1;
		$timetoset = $newstate;
		$timetoset =~ s/INT://;
		if($conftbl{ $key }->{'Log'} > 0) {
			$changes .=  "$key >>>INT$timetoset\|";
			chomp $changes;
		}
		eval( '$command' . " = $protocol_module" . "::build_command (
										command => 'SetPulse',
										protocol => '$conftbl{$key}->{'Proto'}',
										device => '$conftbl{$key}->{'Class'}',
										busaddress => '$conftbl{$key}->{'Bus_address'}',
										port => '$conftbl{$key}->{'Port_num'}',
										targetstate => 'OnPulse',
										pulsetime => $timetoset,
										);");
		$performedcommand = 'SetPulse';
	}
	if ($curstate =~ /OFF/ && $newstate =~ /ON/){
		$changefound = 1;
		if($conftbl{ $key } {'Log'} > 0) {
			$changes .=  "$key >>>ON\|";
			chomp $changes;
		}
		eval( '$command' . " = $protocol_module" . "::build_command (
										command => 'SetState',
										protocol => '$conftbl{$key}->{'Proto'}',
										device => '$conftbl{$key}->{'Class'}',
										busaddress => '$conftbl{$key}->{'Bus_address'}',
										port => '$conftbl{$key}->{'Port_num'}',
										targetstate => 'ON',
										);");
		$performedcommand = 'SetState';
	}

	if ($curstate =~ /ON/ && $newstate =~ /OFF/){
	$changefound = 1;
		if($conftbl{ $key } {'Log'} > 0) {
			$changes .= "$key >>>OFF\|";
			chomp $changes;
		}	
		eval( '$command' . "= $protocol_module" . "::build_command (
										command => 'SetState',
										protocol => '$conftbl{$key}->{'Proto'}',
										device => '$conftbl{$key}->{'Class'}',
										busaddress => '$conftbl{$key}->{'Bus_address'}',
										port => '$conftbl{$key}->{'Port_num'}',
										targetstate => 'OFF',
										);");
		$performedcommand = 'SetState';
	}
	unless ( $changefound ) {
		next;
	}
	unless ( defined $command ) {
#		$conftbl{ $key } {'CurState'}  = "ERROR:BuildComm"; 			# no change command sent, e.g. no state change
																		printlog (2, "Building change command failed");
		next;															
	} 
	
			
#------------------------------	
# write settings to Quido
#------------------------------

																		
	my $curstat = "";
	if ($TESTING eq 'YES') {
		print $command . "\n";
		$conftbl{ $key } {'CurState'}  = $command;
	} else {
#			my $curstat;
		my $sendresult;
#			my $dataread = "";
#																	print "Databuffer: " . \$curstat . " / $curstat\n";
		if ( defined ($conftbl{$key}->{'Gateway'}  ) ) {
			$sendresult = send_command2 ( $command, $gwtab{ $conftbl{$key}->{'Gateway'} }->{'NetAddress'}, $gwtab{ $conftbl{$key}->{'Gateway'} }->{'NetPort'}, \$curstat, $registered_protocols{$conftbl{$key}->{'Proto'}}{'continuecallback'});
		} else {
			$sendresult = send_command2 ($command, $remote, $port, \$curstat, $registered_protocols{$conftbl{$key}->{'Proto'}}{'continuecallback'});
		}
		unless ($sendresult eq "COM_SUCCESS") {
#				$conftbl{ $key } {'CurState'} = "ERROR:$sendresult";
																	printlog (2, "Sending change state command failed: $sendresult");
			next;															
		}

		my $responsecode;			
		my $curstatptr = \$curstat;
		my $evalstring = '$responsecode' . " = $protocol_module" . "::translate_response (
												command => '$performedcommand',
												sentcommand => '$command',
												response => '$curstat',
												protocol => '$conftbl{$key}->{'Proto'}',
												device => '$conftbl{$key}->{'Class'}',
												responsedataptr => " . '$curstatptr' . ",
												targetstate => ''
												);";
#																		print "Translate string: $evalstring\n";
		eval($evalstring);
		
		unless ( $responsecode eq 'PROTO-OK' ) {
																printlog (2, "Error sending command: $key - $responsecode");
#				$conftbl{$key}->{'State'} = $responsecode;
# Rollback pair step change if pair member command failed													
			if ( defined $conftbl{$key}->{'Requester'} ) {
				write_curstep ($conftbl{$key}->{'Requester'}, $conftbl{$conftbl{$key}->{'Requester'}}{'CurState'});
			}
		} else {
																printlog (4, "Command accepted");											
			$conftbl{$key}->{'State'} = $conftbl{$key}->{'NewState'};
			if ( defined $timetoset ) {
				my ($csec,$cmin,$chour,$cmday,$cmon,$cyear,$cwday,$cyday,$cisdst) = localtime (time + $timetoset);
				$cyear += 1900;
				$cmon++;
				$conftbl{$key}->{'CommandEnd'} = sprintf ("%02d",$cyear) . ':' . sprintf ("%02d", $cmon) . ':' . sprintf ("%02d", $cmday) . ':' . sprintf ("%02d", $chour) . ':' . sprintf ("%02d",$cmin) . ':' . sprintf ("%02d",$csec);
			}
																# tady by se dal zapsat stav podle prikazu, pokud to vratilo OK, prikaz se provedl
		}
																
		$evalstring = '$command' . " = $protocol_module" . "::build_command (
												command => 'ReadState',
												protocol => '$conftbl{$key}->{'Proto'}',
												device => '$conftbl{$key}->{'Class'}',
												busaddress => '$conftbl{$key}->{'Bus_address'}',
												port => '$conftbl{$key}->{'Port_num'}',
												targetstate => '',
												);";
#																		print "Command string:$evalstring\n";
		eval ($evalstring);		
		unless (defined $command) {
#				$conftbl{ $key } {'CurState'}  = "ERROR:BuildComm";
																	printlog (2, "Building read after change command failed");
			next;															
		}
		
#----------
#																print "Read state : $key: $command    \n";	
#																my @commandarray = split ('', $command );
#																foreach my $compart (@commandarray ) {
#																	print sprintf ("%02X", ord($compart)).' ';
#																}
#																print "\n";



		undef $sendresult;
		$curstat = "";
#				my $dataread = "";
		if ( defined ($conftbl{$key}->{'Gateway'}  ) ) {
			$sendresult = send_command2 ( $command, $gwtab{ $conftbl{$key}->{'Gateway'} }->{'NetAddress'}, $gwtab{ $conftbl{$key}->{'Gateway'} }->{'NetPort'}, \$curstat, $registered_protocols{$conftbl{$key}->{'Proto'}}{'continuecallback'});
		} else {
			$sendresult = send_command2 ($command, $remote, $port, \$curstat, $registered_protocols{$conftbl{$key}->{'Proto'}}{'continuecallback'});
		}
		unless ($sendresult eq "COM_SUCCESS") {
#		$conftbl{ $key } {'CurState'} = "ERROR:$sendresult";
																	printlog (2, "Reading state after change communication failed $sendresult");
			next;															
		}
#																print "Read change state response $key: $curstat\n";
																	printlog (5, " Data read: $curstat");
#																my @responsearray = split ('', $curstat );
#																foreach my $resppart (@responsearray ) {
#																	print sprintf ("%02X", ord($resppart)).' ';
#																}
#																print "\n";


#------------
#				if ( defined ($conftbl{$key}->{'Gateway'}  ) ) {
#					$curstat = send_command2 ( $command, $gwtab{ $conftbl{$key}->{'Gateway'} }->{'NetAddress'}, $gwtab{ $conftbl{$key}->{'Gateway'} }->{'NetPort'});
#				} else {
#					$curstat = send_command2 ($command, $remote, $port);
#				}
#				unless (defined $curstat ) {
#					$curstat = "ERROR-CHECK";
#				}

		if (  $sendresult eq "COM_SUCCESS"  ) {			#tenhle test je tu nanic, vyhodit
			my $responsecode;
			my $curstatptr = \$curstat;
			my $evalstring = '$responsecode' . " = $protocol_module" . "::translate_response (
													command => 'ReadState',
													sentcommand => '$command',
													response => '$curstat',
													protocol => '$conftbl{$key}->{'Proto'}',
													device => '$conftbl{$key}->{'Class'}',
													responsedataptr => " . '$curstatptr' . ",
													targetstate => ''
													);";
#																		print "Translate string: $evalstring\n";
			eval($evalstring);

		}
		unless (defined $responsecode) {
#				$conftbl{ $key } {'CurState'}  = "ERROR:TranslateResp";
																			printlog (2, "Translating read state after response failed");
			next;															
		}
		unless ($responsecode eq "PROTO-OK") {
			$conftbl{ $key } {'CurState'} = "ERROR:$responsecode";
																			printlog (2, "Reading state failed $responsecode");
			next;															
		}
		$conftbl{ $key } {'CurState'}  = $curstat;
		
# !!! comment out for testing purposes
#		$conftbl{ $key } {'CurState'}  = $curstat;
#	write_curstate ( $key, $curstat );
#					print "\nResult read          : $curstat";
	}
	if ($TESTING eq 'YES') {
		$conftbl{ $key } {'CurState'}  = $command;
		print $command . "\n";
	}
} 

close_all();
#-----------------------------------------------
# process status table - write current states
#-----------------------------------------------

write_last_states ( \%conftbl, $stattable, $year . ':' . sprintf( "%02d", $mon) . ':' . sprintf( "%02d", $mday) . ":" . sprintf( "%02d", $hour) . ":" . sprintf( "%02d", $min) );

#-----------------------------------------------
# process status table - write operation log
#-----------------------------------------------

my $states = "";
my $ldate = $year . '-' . sprintf( "%02d", $mon) . '-' . sprintf( "%02d", $mday) . "-" . sprintf( "%02d", $hour) . "-" . sprintf( "%02d", $min);
foreach my $key (keys %conftbl) {
	my ($moduleloglevel, $moduleloginterval);
	if ( $conftbl{ $key } {'Log'} =~ /,/ ) {
		($moduleloglevel, $moduleloginterval) = split /,/ , $conftbl{ $key } {'Log'};
	}else{
		$moduleloglevel = $conftbl{ $key } {'Log'};
	}
	unless ( defined ( $moduleloginterval ) ){
		$moduleloginterval = 1;
	}
	unless ( $changes =~ /[^\|]\s*$key\s*\>\>\>/ ) {
		if ( ((60 * $hour + $min) % $moduleloginterval ) == 0 ) {
			if ( $moduleloglevel > 1 ) {
				$states = $states . $key . "=" . $conftbl{ $key }->{'CurState'} . "\|";
			}
			if ( $moduleloglevel == 1 ) {
				if ((! defined ( $conftbl{ $key }->{'LastState'})) or  ( $conftbl{ $key }->{'CurState'} ne $conftbl{ $key }->{'LastState'} ) ) {
					$states = $states . $key . "=" . $conftbl{ $key }->{'CurState'} . "\|";
				}
			}	
		}
	}
} 

#$states =~ s/$EOL//g; 
$changes =~ s/\n//g;
$changes =~ s/(\D)0(\d)/$1$2/g;
$states =~ s/(\D)0(\d)/$1$2/g;
if (length ($changes . $states) > 1) {
	$changes =~ s/\|$//;
	open (LTB, ">>$logtable");
	print LTB "$ldate\|$states" . "$changes\n";
	close (LTB);
}

unlink $lockfile;
exit;

#===============================================================================
# Procedures
#===============================================================================


# evaluates whether the locmins (i.e. the current minute of the day) is within the interval timefrom - timeto
# ... event if the interval contains a midnight
sub evaluatetimes
{
	my $timefrom = shift;
		my $timeto = shift;
	my $locmins = shift;
	my $newstate = 'OFF';
	
	my $frommins = (60 * int($timefrom / 100)) + ($timefrom % 100);
	my $tomins = (60 * int($timeto / 100)) + ($timeto % 100);
#							print "     times: from=$frommins to=$tomins cur=$locmins\n";

	if ($frommins <= $tomins) {
		if ($frommins <= $locmins && $tomins > $locmins) {
			$newstate = 'ON';
		} else {
			$newstate = 'OFF';
		}
	} else {
		if ($frommins <= $locmins || $tomins > $locmins) {
			$newstate = 'ON';
		} else {
			$newstate = 'OFF';
		}
	}
	return $newstate;
}
			
# Future use
			
sub check_group
{


}	

# MOVED TO ICONFIG
# compares the endtime in the form YYYY:MM:DD:hh:mm with current time / checktime if specified
# returns 1 if the endtime is greater than the current time / checktime
# sub compare_endtime
# {
	# my $endtime = shift;
	# my $checktime = shift;

# #																		print "   Comparing $endtime vs $checktime\n";
	# unless (defined ( $endtime ) ){
		# return 0;
	# }
	# unless ( $endtime =~ /\d\d\d\d:\d\d:\d\d:\d\d:\d\d/ ) {
		# return 0;
	# }
	# my ($eyear, $emonth, $eday, $ehour, $emin) = split /:/, $endtime;
	# my ($csec,$cmin,$chour,$cmday,$cmon,$cyear,$cwday,$cyday,$cisdst);
	# if ( defined $checktime ) {
		# ($csec,$cmin,$chour,$cmday,$cmon,$cyear,$cwday,$cyday,$cisdst) = localtime ($checktime);
		# $cyear += 1900;
		# $cmon++;
	# } else {
		# ($csec,$cmin,$chour,$cmday,$cmon,$cyear,$cwday,$cyday,$cisdst) = ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst);
	# }

	
	# if (($eyear == 0) && ($emonth == 0) && ($eday == 0) && ($ehour == 0) && ($emin == 0)) {
		# return 1;
	# }
	# if ( $eyear < $cyear ) {
		# return 0;
	# }
	# if ( $eyear > $cyear ) {
		# return 1;
	# }
	# if ( $emonth < $cmon ) {
		# return 0;
	# }
	# if ( $emonth > $cmon ) {
		# return 1;
	# }
	# if ( $eday < $cmday ) {
		# return 0;
	# }
	# if ( $eday > $cmday ) {
		# return 1;
	# }
	# if ( $ehour < $chour ) {
		# return 0;
	# }
	# if ( $ehour > $chour ) {
		# return 1;
	# }
	# if ( $emin <= $cmin ) {
		# return 0;
	# }
	# return 1;
# }
	
#central Condition parameter evaluation
# WDAY ... if current day equals to specified week day
# RDAY ... every n-th day beginning from 1.1.
# DATE ... exact date
# &<module>[<>=]<value>
# EXP: (subcond1 OR subcond2) AND subcond3 OR (NOT (subcond4) AND (subcond5 OR subcond6))
# Returns: 1 iff condition is met, 0 iff not, -1 iff could not be determined
sub evaluate_condition
{
	my $condition = shift;
	my $level = shift;
	my $conditionmet = 1;
																		printlog (5, ">$level< Evaluating: $condition");
	if( $condition =~ /^EXP:/ ) {
		$condition =~ s/^EXP:\s*//;
		my @parenthesis;
		while ( $condition =~ /\(([^\(\)]*)\)/ ){
			push @parenthesis, $1;
#																		print ">$level<    Pushed: $1 - " . $#parenthesis . "\n";
			my $index = '___' . $#parenthesis . '___';
			$condition =~ s/\([^\(\)]*\)/$index/;
		}
#																		print ">$level<       Substitued: $condition\n";
		my @orparts = split ( ' OR ', $condition );
		$conditionmet = 0;
		foreach my $orpart (@orparts) {
#																		print ">$level<            Orpart: $orpart\n";
			my @andparts = split ( ' AND ', $orpart );
			my $internalresult = 1;
			my $notpresent = 0;
			foreach my $andpart ( @andparts ) {
				if ( $andpart =~ /^\s*NOT/ ) {
					$notpresent = 1;
					$andpart =~ s/^\s*NOT//;
				}
				while ( $andpart =~ /___(\d+)___/ ) {
					my $insert = $parenthesis[$1];
#																		print ">$level<             Poped: $parenthesis[$1]\n";
					$andpart =~ s/___\d+___/\($insert\)/;
				
				}
#																		print ">$level<    Recalled: $andpart\n";
				if ( $andpart =~ /^\s*\((.*)\)\s*$/ ){
					my $legal = 0;
					foreach  my $char ( split //, $1 ) {
						if ($char eq '(' ) {
							$legal = $legal + 1;
						}
						if ($char eq ')' ) {
							$legal = $legal - 1;
						}
						if ( $legal < 0 ) {
							last;
						}
					}
					if ( $legal == 0 ) {
						$andpart =~ s/^\s*\((.*)\)\s*$/$1/;
					}
				}
					
				$andpart =~ s/^\s*\(([^\(]*\()\)\s*$/$1/;
#																		print ">$level<    Stripped: $andpart\n";
				if ( $andpart =~ / AND | OR / ) {
					$andpart = 'EXP:' . $andpart;
				}
				my $result = evaluate_condition( $andpart, $level + 1 );
				if ( $result == -1 ) {
					return $result;
				}
				if ( $notpresent ) {
					$result = not ( $result );
				}
				unless ( $result ) {
					$internalresult = 0;
					last;
				}
			}
			if ( $internalresult ) {
				$conditionmet = 1;
				last;
			}
		}
	}else{
	
		if( $condition =~ /WDAY:/ ) {
			$condition =~ /WDAY:([^;]*)/;
			if ($wday < 1) {
				$wday = 7;
			}
			my $wdayfound = 0;
			my @condays = split (';', $1);
			foreach my $cday (@condays) {
				if ($cday eq $wday ) {
					$wdayfound = 1;
					last;				
				}
			}
			unless ($wdayfound) {
				$conditionmet = 0;
			}
		}
		if( $condition =~ /RDAY:/i ) {
			$condition =~ /RDAY:([^;]*)/i;
			if ( $yday % $1 != 0  ) {
	#					print "     ourday: $1 \n";
				$conditionmet = 0;
			}
		}
		if( $condition =~ /DATE:/ ) {
			$condition =~ /DATE:([^;]*)/;
	#		$mon += 1;
	#		$year += 1900;
			my ($reqday, $reqmonth, $reqyear) = split /\./, $1;
	#		unless ( "$mday.$mon.$year"  eq $1  ) {
	#																		print "Condition $mday =? $reqday ... $mon =? $reqmonth ... $year =? $reqyear \n";
			unless ( ($reqday == $mday) && ($reqmonth == $mon) && ($reqyear == $year)) {
	#																		print "Condition missed!\n";
				$conditionmet = 0;
			}
		}
		if( $condition =~ /\&/ ) {
			$condition =~ /\&(.*)/;
			my $checkmodul = $1;
			my @condparts = split( ';', $1);
			foreach my $condpart (@condparts) {

				my $relname = $condpart;
				my $relstate = $condpart;
	#																		print "Condpart : $condpart\n";
				$relname =~ /^([^><:=]+)/;
				my $ccond = get_newstate ( $1 );
#																			print "Read condition state $relname: $ccond\n";
				if ( $ccond eq 'ERROR:NODET' ) {
					$conditionmet = -1;
					last;
				}

				$ccond =~ s/.*[:=]\s*//;					#tady odstranit : az Leos naimplementuje = v podmince
	#			chomp $ccond;
				if ( $condpart =~ />/ ) {
					$relname =~ s/([^>]+).*/$1/;
					$relstate =~ s/.*>(.+)/$1/;
	#																		print "Required $relstate  found $ccond\n"; 
					unless (  $ccond > $relstate ) {
						$conditionmet = 0;
						last;
					}
				}elsif ( $condpart =~ /</ ) {	
					$relname =~ s/([^<]+).*/$1/;
					$relstate =~ s/.*<(.+)/$1/;
					unless ( $ccond < $relstate ) {
						$conditionmet = 0;
						last;
					}
				}else {
					$relname =~ s/([^:^=]+).*/$1/;				#tady odstranit : az Leos naimplementuje = v podmince
					$relstate =~ s/.*[:=](.+)/$1/;				#tady odstranit : az Leos naimplementuje = v podmince
	#																		print "          relname :   $relname \n";
	#																		print "          relstate:   $relstate \n";																		
	#																		print "          cond    :   $ccond \n";
					unless ( $ccond eq $relstate ) {
						$conditionmet = 0;
						last;
					}
				}
			}	
		}	
	}
																			printlog  (5, "Evaluated: $condition =>$conditionmet " );
	return $conditionmet;
}

# Central function for reading actual state of the module specified
# Returns state read during last state-reading round
# If not available, returns last known state from last_states table, if MaxBlindTime is not exceeded
# Returns ERROR:UNKNOWN otherwise
sub read_curstate
{
	my $ModuleName = shift;
	my $Item = shift;
	
	my $StateRead = $conftbl{$ModuleName}{'CurState'};
	if ( $StateRead =~ /ERROR/ ) {
		if ( defined $conftbl{$ModuleName}{'MaxBlindTime'} ) {
			my $blindtime = $conftbl{$ModuleName}{'MaxBlindTime'};
			$blindtime =~ s/\s*(\d*).*/$1/;
			if ( $conftbl{$ModuleName}{'MaxBlindTime'} =~ /H/ ) {
				$blindtime *= 60;
			}
			if ( $conftbl{$ModuleName}{'MaxBlindTime'} =~ /D/ ) {
				$blindtime *= 60*24;
			}
			my $oldesttime = $unixtime - $blindtime * 60;
			if ( compare_endtime ($conftbl{$ModuleName}{'LastTime'}, $oldesttime) ) {
				$StateRead = $conftbl{$ModuleName}{'LastState'};
			} 
			
		} else {
			$StateRead = $conftbl{$ModuleName}{'LastState'};
		}
	}
	if (defined $Item ) {
		$StateRead =~ s/.*$Item\s*:\s*([^,]+).*/$1/;
	} else {
		$StateRead =~ s/^[^:]+:\s*([^,]+).*/$1/;
	}
	if ( defined $StateRead ) {
		return $StateRead;
	} else {
		return "ERROR:UNKNOWN";
	}
}

sub write_curstate														# obsahuje chybu (zdvojuje navesti stavu), nepouziva se nikde
{
	my $ModuleName = shift;
	my $StateToWrite = shift;
	my $Item = shift;
	
	my $StateRead = $conftbl{$ModuleName}{'CurState'};
	if ( defined $Item ) {
		if ( $StateRead =~ /$Item/ ) {
			$StateRead =~ s/($Item\s*:\s*)[^,]+(.*)/$1$StateToWrite $2/;
		} else {
			$StateRead = $StateRead . ";$Item:$StateToWrite";
		}
	} else {
		$StateRead =~ s/(^[^:]+:\s*)[^,]+(.*)/$1$StateToWrite $2/;
	}
	$conftbl{$ModuleName}{'CurState'} = $StateRead;
}

# Loads last states from config.local/StatTable
# Adds LastState and LastTime to central statetable hash

sub load_last_states
{
	my $statefilehdl = shift;
	my $statetableptr = shift;
	
	while ( <$statefilehdl> ) {
		unless ($_ =~ /=/ ) {
			next;
		}
#		print $_ ;
		chomp $_;
		my ($modulename , $moduleinfo) = split ( '=', $_ );
		if ( $modulename =~ /^_.*_$/ ) {
			next;
		}
		my ($modulestate, $statetime) = split ( ';', $moduleinfo);
		$modulename =~ s/^ //g;
		$modulename =~ s/ $//g;
		$modulestate =~ s/^\s*//;
		
		$$statetableptr{$modulename}{'LastState'} = $modulestate;
		$$statetableptr{$modulename}{'LastTime'} = $statetime;
	}
}

# Central function for reading new state of the module specified 
# ON Qport, Qpair type returns NewState, on all others returns CurState
# If NewState is not determined yet, returns ERROR:NODET

sub get_newstate
{
	my $ModuleName = shift;
#	my $Item = shift;
	
	if (defined ( $conftbl{$ModuleName} ) ) {
		my $StateRead;
		if ( defined $conftbl{$ModuleName}{'NewState'} ) {
			$StateRead = $conftbl{$ModuleName}{'NewState'};
		} elsif ( ($conftbl{$ModuleName}{'Class'} eq 'THT') or ($conftbl{$ModuleName}{'Class'} eq 'Qinpt') or ($conftbl{$ModuleName}{'Class'} eq 'Qctr') or ($conftbl{$ModuleName}{'Class'} eq 'Qterm') ) {
			$StateRead = $conftbl{$ModuleName}{'CurState'};
		}	
		if ( defined ( $StateRead ) ) {
			return $StateRead;
		}
	}
	return 'ERROR:NODET';
}



# checks for errors and sends warning if found any
#	last states table is analyzed
#		recognized errors:
#			module state not acquired longer than global delay_global
#			module state not acquired longer than corresponding delay_<module_name> parameter
# all parameters set at [Watchdog] section of global config file
sub watchdog_check
{
	my $Message = "";
	my $SubjectStateSuffix = " >>ERROR<<";
	my $globaldelay;
#	my %statestable;

# reset error message counter if appropriate
	my $problemfound = 0;
	
	unless ( defined ( $watchdogtab{'Watchdog'}{'Messages_today'} ) ) {
		$configtab{'Watchdog'}{'Messages_today'} = 0;
	}
	unless ( defined ( $configtab{'Watchdog'}{'CheckTime'} ) ) {
		$configtab{'Watchdog'}{'check_time'} = 1600;
	}
	
	$configtab{'Watchdog'}{'CheckTime'} =~ s/(\d\d)(\d\d)/$1:$2/;
	if ( $watchdogtab{'Watchdog'}{'Next_reset'} le sprintf( "%02d", $year) . ':' . sprintf( "%02d", $mon) . ':' . sprintf( "%02d", $mday) . ":" . sprintf( "%02d", $hour) . ":" . sprintf( "%02d", $min) ) {
		$watchdogtab{'Watchdog'}{'Messages_today'} = 0;
#		my $resetday = $watchdogtab{'Watchdog'}{'Next_reset'};
#		$resetday =~ s/\d*:\d*:(\d+):.*/$1/;
		my $nextresettime = $unixtime;
		if ( $configtab{'Watchdog'}{'CheckTime'} le sprintf ( "%02d", $mday) . ':' . sprintf ( "%02d", $min) ) {
			$nextresettime += 60*60*24;
		}
		my ($rsec,$rmin,$rhour,$rmday,$rmon,$ryear,$rwday,$ryday,$risdst) = localtime ( $nextresettime );
		$ryear += 1900;
		$rmon++;
		$watchdogtab{'Watchdog'}{'Next_reset'} = sprintf ("%02d", $ryear) . ':' . sprintf ("%02d", $rmon) . ':' . sprintf ("%02d", $rmday) . ':' . $configtab{'Watchdog'}{'CheckTime'};
	}
# look for errors	
	foreach my $key (keys %{$configtab{'Watchdog'}}) {
		unless ( $key =~ /^Delay_/i ) {
			next;
		}
																		
		my $delay =  $configtab{'Watchdog'}{$key};
		$key =~ s/\s//g;
		$delay =~ s/\s//g;
		my $delaymultiplier = $delay;
		$delaymultiplier =~ s/\d+//;
		$delay =~ s/(\d+).*/$1/;
		if ( $delaymultiplier =~ /m/ ) {
			$delay *= 60;
		}elsif ($delaymultiplier =~ /h/) {
			$delay *= 60*60;
		}elsif ($delaymultiplier =~ /d/ ) {
			$delay *= 60*60*24;
		}
		my $delaytime = $unixtime - $delay;
		$key =~ s/^Delay_//i;
		if ( $key eq 'global' ) {
			$globaldelay = $delaytime;
			next;
		}
#																		print "Found ... $key\n";
		if ( defined $conftbl{$key}{'LastTime'} ) {
#			my ($dsec,$dmin,$dhour,$dmday,$dmon,$dyear,$dwday,$dyday,$disdst) = localtime ( $delaytime );
#			$dyear += 1900;
#			$dmon += 1;
			my $keytime = $conftbl{$key}{'LastTime'};
			$keytime =~ s/;.*//;
#																		print "   ===$delaytime\n";
#			unless ( compare_endtime ($keytime, sprintf( "%02d", $dyear) . ':' . sprintf( "%02d", $dmon) . ':' . sprintf( "%02d", $dmday) . ":" . sprintf( "%02d", $dhour) . ":" . sprintf( "%02d", $dmin)) ) {
			unless ( compare_endtime ($keytime, $delaytime) ) {
#																		print "   PROBLEM - delay exceeded\n";
				$Message .= "Module $key state last read at $keytime exceeding specific limit.\n";
				$problemfound = 1;
			}	
		}
	}
	if ( $globaldelay ) {
#		my ($dsec,$dmin,$dhour,$dmday,$dmon,$dyear,$dwday,$dyday,$disdst) = localtime ( $unixtime - $globaldelay );
#		$dyear += 1900;
#		$dmon += 1;
#		my $testtime = sprintf( "%02d", $dyear) . ':' . sprintf( "%02d", $dmon) . ':' . sprintf( "%02d", $dmday) . ":" . sprintf( "%02d", $dhour) . ":" . sprintf( "%02d", $dmin);
		foreach my $key (keys %conftbl) {
			if ( $key =~ /^_.*_$/ ) {
				next;
			}
						
			my $keytime = $conftbl{$key}{'LastTime'};
			$keytime =~ s/;.*//;
			unless ( compare_endtime ($keytime, $globaldelay) ) {
				$Message .= "Module $key state last read at $keytime exceeding global limit.\n";
				$problemfound = 1;
			}
		}
	}
# decide , what to signal
#	a heartbeat message if everything works good and nothing was reported long enough
#	an alert if there is(are) error(s)
#		... up to daily limit
#		... not before minimal time between alerts is reached
	unless ( $problemfound ) { 
		if (scalar ( keys %{ $watchdogtab{'Unsent'}} ) ) {
			$problemfound = 1;
			$Message = "INITER: unsent errors found.\n";
			$watchdogtab{'Watchdog'}{'Last_message'} = $Message;
			$watchdogtab{'Watchdog'}{'Last_watchdog'} = sprintf ("%02d",$year) . ':' . sprintf ("%02d", $mon) . ':' . sprintf ("%02d", $mday) . ':' . sprintf ("%02d", $hour) . ':' . sprintf ("%02d",$min);
			$SubjectStateSuffix = " >>ERROR<<";
			$Message = $Message . join(", ", map { "$_ : $watchdogtab{'Unsent'}{$_}" } keys %{$watchdogtab{'Unsent'}});
			foreach my $key ( keys %{$watchdogtab{'Unsent'}} ) {
				delete $watchdogtab{'Unsent'}{$key};
			}
			write_watchdogtable ( \%watchdogtab, $configtab{'Watchdog'}{'WatchdogFile'} );
		} else { 
			unless ( $configtab{'Watchdog'}{'ReportDays'} =~ /$wday/ ) {
#				print "Everything looks good, no action necessary\n";
				return 1;
			}
			if ( sprintf ("%02d", $hour) . ':' . sprintf ("%02d",$min)  lt $configtab{'Watchdog'}{'CheckTime'} ) {
				print sprintf ("%02d", $hour) . ':' . sprintf ("%02d",$min) . ' / ' . $configtab{'Watchdog'}{'CheckTime'} . "Everything looks good, too early to report\n";
				return 1;
			}
			my ($wyear,$wmon,$wday,$whour,$wmin) = split (':' ,$watchdogtab{'Watchdog'}{'Last_watchdog'});
			if ( ($wyear == $year) && ($wmon == $mon) && ($wday == $mday) ) {
#				print "Everything looks good, already reported\n";
				return 1;
			}
			$Message = "INITER: everything looks goog so far!\n" . $Message;;
			$SubjectStateSuffix = " >>GOOD<<";
			$watchdogtab{'Watchdog'}{'Last_message'} = $Message;
			$watchdogtab{'Watchdog'}{'Last_watchdog'} = sprintf ("%02d",$year) . ':' . sprintf ("%02d", $mon) . ':' . sprintf ("%02d", $mday) . ':' . sprintf ("%02d", $hour) . ':' . sprintf ("%02d",$min);
			write_watchdogtable ( \%watchdogtab, $configtab{'Watchdog'}{'WatchdogFile'} );
		}
	} else {
		
		if ( $watchdogtab{'Watchdog'}{'Messages_today'} >= $configtab{'Watchdog'}{'MaxAlertsPerDay'} ) {
			$watchdogtab{'Unsent'}{sprintf ("%02d",$year) . ':' . sprintf ("%02d", $mon) . ':' . sprintf ("%02d", $mday) . ':' . sprintf ("%02d", $hour) . ':' . sprintf ("%02d",$min)} = $Message;
			write_watchdogtable (\%watchdogtab, $configtab{'Watchdog'}{'WatchdogFile'});
			exit 1;
		}
		if ( $Message eq $watchdogtab{'Watchdog'}{'Last_message'} ) {
			$watchdogtab{'Unsent'}{sprintf ("%02d",$year) . ':' . sprintf ("%02d", $mon) . ':' . sprintf ("%02d", $mday) . ':' . sprintf ("%02d", $hour) . ':' . sprintf ("%02d",$min)} = $Message;
			write_watchdogtable (\%watchdogtab, $configtab{'Watchdog'}{'WatchdogFile'});
			exit 1;
		}

#			my ($wyear,$wmon,$wday,$whour,$wmin) = split (':' ,$watchdogtab{'Watchdog'}{'Last_watchdog'});
		my $watchdogdist;
		$watchdogdist = $configtab{'Watchdog'}{'TimeBetweenAlerts'};
		if ($watchdogdist =~ /m/ ) {
			$watchdogdist =~ s/m//;
			$watchdogdist *= 60;
		}
		
		if (compare_endtime ($watchdogtab{'Watchdog'}{'Last_watchdog'}, $unixtime - $watchdogdist ) ) {
			$watchdogtab{'Unsent'}{ sprintf ("%02d",$year) . ':' . sprintf ("%02d", $mon) . ':' . sprintf ("%02d", $mday) . ':' . sprintf ("%02d", $hour) . ':' . sprintf ("%02d",$min)} = $Message;
			write_watchdogtable (\%watchdogtab, $configtab{'Watchdog'}{'WatchdogFile'});
			exit 1;
		}
		$watchdogtab{'Watchdog'}{'Last_message'} = $Message;
		$watchdogtab{'Watchdog'}{'Last_watchdog'} = sprintf ("%02d",$year) . ':' . sprintf ("%02d", $mon) . ':' . sprintf ("%02d", $mday) . ':' . sprintf ("%02d", $hour) . ':' . sprintf ("%02d",$min);
		$Message = $Message . join(", ", map { "$_ : $watchdogtab{'Unsent'}{$_}" } keys %{$watchdogtab{'Unsent'}});
		$SubjectStateSuffix = " >>ERROR<<";
		foreach my $key ( keys %{$watchdogtab{'Unsent'}} ) {
			delete $watchdogtab{'Unsent'}{$key};
		}
		write_watchdogtable ( \%watchdogtab, $configtab{'Watchdog'}{'WatchdogFile'} );
	}
	
#																		print "Result:\n\n$watchdogsubject $SubjectStateSuffix\n$Message\n";
#																		return 1;
	
	my $msg = MIME::Lite ->new (  
	
			From => 'DOHLED@inforoom.cz',
			To => $watchdogaddressee,
			Subject => $watchdogsubject . ' ' . $SubjectStateSuffix,
			Data => $Message,
			Type => 'text/html'
		);

	my $smtps = Net::SMTP->new($watchdogserver, Port => $watchdogserverport,  doSSL => $watchdogserverssl, SSL_version=> $watchdogserversslversion);

	$smtps->auth( $watchdoguser, $watchdogpassword ) or die("Could not authenticate with watchdog alert sending server.\n");
	$smtps ->mail('beda@inforoom.cz');
	$smtps->to( $watchdogaddressee);
	$smtps->data();
	$smtps->datasend( $msg->as_string() );  
	$smtps->dataend();  
	$smtps->quit;
	
}	

# Writes new watchdog table
sub write_watchdogtable
{
	my $watchdogtableptr = shift;
	my $watchdogtable = shift;
	my $watchdogtablehdl;
	
	open ($watchdogtablehdl, ">$watchdogtable");
	
	unless ( defined ( $watchdogtablehdl ) ) {
																		printlog (1, "Unable to write to watchdogtable $watchdogtable" );
		return 0;
	}
	print $watchdogtablehdl "[Watchdog]\n";
	foreach my $key (keys %{$$watchdogtableptr{'Watchdog'}}) {
		print $watchdogtablehdl "$key=" . $$watchdogtableptr{'Watchdog'}{$key} . "\n";
	}
	print $watchdogtablehdl "[Unsent]\n";
	foreach my $key (keys %{$$watchdogtableptr{'Unsent'}}) {
		print $watchdogtablehdl "$key=" . $$watchdogtableptr{'Unsent'}{$key} . "\n";
	}
	close $watchdogtablehdl;
	return 1;
}

# Checks whether module is still running previous command
sub is_running
{
	my $targetmodule = shift;
	
	unless ( defined $conftbl{$targetmodule}{CommandEnd} ) {
		return 0;
	}
	if ( $conftbl{$targetmodule}{CommandEnd} lt sprintf ("%02d",$year) . ':' . sprintf ("%02d", $mon) . ':' . sprintf ("%02d", $mday) . ':' . sprintf ("%02d", $hour) . ':' . sprintf ("%02d",$min) . ':' . sprintf ("%02d",$sec) ) {
		return 0;
	}
	return 1;
}

# TODO

# effect checking
# human input integration
# Parallel::ForkManager
 
# dpulse, pulse
# doplneni podminky (vice dnu, nasobn0 podminky)
# zavest verzovani a testovani verzi knihoven
# omezeni na velikost logu - max velikost na jeden beh, max velikost celkem
# grupovani dotazu - cist najednou vsechny vstupy/vystupy zarizeni

