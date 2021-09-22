#!/usr/bin/perl

# plans sequence 
# params:
#					[start=<time>]
#					[date=<date>]
#					[state=ON|OFF|<pnumber>
#					members={<module_i>:<time_i>}  ... (comma separated list)
# example:	immediate_sequence start=0230 date=23.02.2021 members=ZVJezirko:10,ZVVjezd:15,ZVStred:20,ZVLouka:10 state='ON'



use IO::Handle;
use IO::Socket;
use IO::Socket::INET;
use IO::Select;
use strict;
use warnings;
use Time::Local;
use lib '.';
use iconfig '1.03.04';
use iconfig qw (get_curstep write_curstep read_last_states write_last_states compare_endtime write_manual);

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

our ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime ();
	$year += 1900;
	$mon += 1;
my $etime = time();


	
# Read configurations (using phpconfig locate main, working, current)

if ( -r $mainphpconfig) {
	open ($filehandle, "$mainphpconfig") || die "Plan_seq: Can't open $mainphpconfig: $!\n";
#	$configtype = 'PHP';
} elsif ( -r $testphpconfig) {
	open ($filehandle, "$testphpconfig") || die "Plan_seq: Can't open $testphpconfig: $!\n";
#	$configtype = 'PHP';
} else {
	die "Plan_seq: Can't find $mainphpconfig!\n";
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
# Set GLOBAL VARIABLES	
our $logfile = $configmain{'log'}->{'file'};
our $logto = $configmain{'log'}->{'logto'};

if ( defined (	$configmain{'log'}->{'level'} ) ) {
	$loglevel = $configmain{'log'}->{'level'};
}

																		printlog (1, "Imm_Seq: -- Starting -- Params: $args");
#																        print "Imm_Seq: -- Starting -- Params: $args <BR>\n";

# Set GLOBAL VARIABLES	
$TESTING = $configmain{'Global'}->{'TESTING'};
unless ( defined $TESTING ) {
	$TESTING='NO';
}

open ($filehandle, $configphpwork{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
											print "Nelze otevřít pracovní konfiguraci $configphpwork{'Global'}->{'ConfigTable'}, končím!";
											exit;
											};
while (my $line = <$filehandle>) {
	push (@worklines, $line);
}
close $filehandle;
open ($filehandle, $configphpact{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
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

# parse command line options
my $starttime;
my $startdate;
my $members;
my $mstate = 'ON';

foreach my $argument (@ARGV) {
	if ( $argument =~ /start=(.+)/ ){
		$starttime = $1;
		$starttime =~ s/'//g;
	#												print "StartTime--$starttime\n";
	}
		if ( $argument =~ /date=(.+)/ ){
		$startdate = $1;
		$startdate =~ s/'//g;
	#												print "StartDate--$startdate\n";
	}

	if ( $argument =~ /members=(.+)/ ){
		$members = $1;
		$members =~ s/'//g;
	#												print "Members--$members\n";
	}
	if ( $argument =~ /state=(.+)/ ){
		$mstate = $1;
		$mstate =~ s/'//g;
	#												print "ManState--$mstate\n";
	}

}



#											print "ManualDate--$manualdate\n";
#Use start date / time set in parameters if any
if ( defined ( $starttime ) ) {
	$hour = int ( $starttime  / 100 );
	$min = $starttime % 100;
}
if ( defined ( $startdate ) ) {
	( $mday, $mon, $year ) = split ( /\./, $startdate );
}
		
$etime = timelocal($sec, $min, $hour, $mday, $mon-1, $year-1900);	
if ( $etime < time() ) {
	$etime += 60 * 60 * 24;
}
	
#	$targettime = sprintf ("%04d", $year) . ':' . sprintf ("%02d", $mon) . ':' . sprintf ("%02d", $mday) . ':' . sprintf ("%02d", $hour) . ':' . sprintf ("%02d", $min);	
#											print "TargetTime--$targettime\n";


while ($members =~ /:/) {
	$members =~ s/^([^,]*),*(.*)/$2/;
	my ($member, $duration) = split (/:/, $1);
#																		print " $member -->> $duration \n";
	unless ( defined $configact{$member}->{Class}){
#																		printlog (1, "Plan_seq: Unknown sequence member: $member");
		print "Neexistující člen posloupnosti $member. Žádné změny nebyly provedeny.";
		exit;
	}
	unless ( defined ( $configact{$member}->{'Req_state'} ) ) {
		print "Modul $member není možné zařadit do posloupnosti, ignoruji.\n";
	}
		
	if ( ( $configact{$member}->{'Req_state'} eq 'TIME' ) || ( $configact{$member}->{'Req_state'} eq 'TIMEI' ) || ( $configact{$member}->{'Req_state'} eq 'ON' ) || ( $configact{$member}->{'Req_state'} eq 'OFF' ) ){
		$configact{$member}{'Manual_time_from'} = writetime( $etime );			
		$etime = $etime + $duration * 60;
		$configact{$member}{'Manual_time_to'} = writetime( $etime);
		$configact{$member}{'Manual_state'} = $mstate;
		$configact{$member}{'_Manual_setting_member'} = 1;
#																		print "  number of ints: $#starts \n";
		

		print "$member ... Od $configact{$member}{'Manual_time_from'} do $configact{$member}{'Manual_time_to'}<BR>\n";
		next;
	}
	print "Modul $member není možné zařadit do posloupnosti, ignoruji.\n";
}


open ( $filehandle, ">" . $configphpwork{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
											print "Nelze zapisovat do pracovní konfigurace, končím!";
											exit;
											};
write_manual ($filehandle, \@worklines, \%configact);
close $filehandle;
											
open ( $filehandle, ">" . $configphpact{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
											print "Nelze zapisovat do aktuální konfigurace, končím!";
											exit;
											};
write_manual ($filehandle, \@actlines, \%configact);

close $filehandle;



close $filehandle;
print "\n HOTOVO\n";
exit;
										

#===============================================================================
# Procedures
#===============================================================================

sub writetime
{
	$etime = shift;
	($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime ($etime);
	$year += 1900;
	$mon += 1;
	return sprintf ("%04d", $year) . ':' . sprintf ("%02d", $mon) . ':' . sprintf ("%02d", $mday) . ':' . sprintf ("%02d", $hour) . ':' . sprintf ("%02d", $min);	
}


# sub write_manual2
# {
	# my $confhandle = shift;
	# my $configlinesptr = shift;
	# my $configstructptr = shift;
	
	
	# my $cursection = "";
	# my $insection = 0;
	# my @linebuff = ();
	# my $statefound = 0;
	# my $timetofound = 0;
	# my $timefromfound = 0;
	# my $deletemanual = 0;
	# my $prevsection; 
	# foreach my $line (@$configlinesptr) {
# #												print "Read-->$line\n";
		# my $activeline = $line;
		# $activeline =~ s/#.*//;
		# if( $activeline =~ /^\s*\[([^\[\]]+)\]\s*/ ){
			# $prevsection = $cursection;
			# $cursection = $1;
			# $deletemanual = 0;
			# if ( defined ($$configstructptr{$cursection}{'Manual_state'} ) ) {
				# unless ( compare_endtime( $$configstructptr{$cursection}{'Manual_time_to'} ) ) {
					# $deletemanual = 1;
				# }
			# } 
			# if( defined ($$configstructptr{$cursection}{'_Manual_sequence_member'} ) ) {
# #												print "Target section found\n";
				# $insection = 1;
				# $deletemanual = 0;
			# } else {
				# $insection = 0;
			# }
			# if ( defined ($$configstructptr{$prevsection}{'_Manual_sequence_member'} ) ) { 
				# #								print "Target section leaved\n";
					
				# unless ( $statefound ) {
# #												print "Adding Manual_state->$newstate<--\n";
					# print $confhandle "Manual_state=$$configstructptr{$prevsection}{'Manual_state'}\n";
				# }
				# unless ( $timetofound ) {
# #												print "Adding Manual_time->$newtimeto<--\n";
					# print $confhandle "Manual_time_to=$$configstructptr{$prevsection}{'Manual_time_to'}\n";
				# }
				# unless ( $timefromfound ) {
# #												print "Adding Manual_time->$newtimeto<--\n";
					# print $confhandle "Manual_time_from=$$configstructptr{$prevsection}{'Manual_time_from'}\n";
				# }
			# }
			# while (defined (my $bufline = shift  @linebuff))  {
# #												print "Writting from buffer->$bufline\n";
				# print $confhandle $bufline;
			# }
			# $statefound = 0;
			# $timetofound = 0;
			# $timefromfound = 0;
		# }
		# if( $insection ) {
			# if( $activeline =~ /Manual_time_to/ ) {
# #												print "Updating timeto-->$newtimeto\n";
				# my $newtimeto = $$configstructptr{$cursection}{'Manual_time_to'};
				# $line =~ s/=.*/=$newtimeto/;
				# $timetofound = 1;
			# } 
			# if( $activeline =~ /Manual_time_from/ ) {
# #												print "Updating timeto-->$newtimeto\n";
				# my $newtimefrom = $$configstructptr{$cursection}{'Manual_time_from'};
				# $line =~ s/=.*/=$newtimefrom/;
				# $timefromfound = 1;
			# } 

			# if ( $activeline =~ /Manual_state/ ) {
# #												print "Updating manstate-->$newstate\n";
				# my $newstate = $$configstructptr{$cursection}{'Manual_state'};
				# $line =~ s/=.*/=$newstate/;
				# $statefound = 1;
			# }
			# $activeline =~ s/\s//g;
# #												print "actline--|$activeline|--\n";
			# if ( length ( $activeline ) > 0 ) {
				# while (defined (my $bufline = shift  @linebuff ) )  {
# #												print "Writting from buff->$bufline\n";
					# print $confhandle $bufline;
				# }
			# } else {
				# push ( @linebuff, $line );
# #												print "Buffering-->$line\n";
				# next;
			# }
# #			if ( $activeline =~ /Manual_time_from/ ) {
# #												print "Removing manstatefrom\n";
# #				next;
# #			}

		# }
# #												print "Writting -->$line\n";
		# if ( $deletemanual ) {
			# unless ($line =~ /Manual_state/ || $line =~ /Manual_time_to/ || $line =~ /Manual_time_from/ ) {
				# print $filehandle $line;
			# }
		# } else {
			# print $filehandle $line;
		# }
	# }
# }	

# # compares active and working configuration
# #   ... skippint comments and manual configuration
# #   ... and removes uncecessary manual_* settings
# sub compare_config
# {
	# my $firstconfigptr = shift;
	# my $secondconfigptr = shift;

	# my $firstindex = 0;
	# my $secondindex = 0;
	# my $coupled = 0;
	# while (defined ( $$firstconfigptr[$firstindex]) && defined ($$secondconfigptr[$secondindex]) ) {																																																																																																																																																																														
		# my $firstactive = $$firstconfigptr[$firstindex];
		# $firstactive = canonize_active ( $firstactive );
# #		if (length ( $firstactive ) < 1 ) {
# # Manual_state_hack ----
		# if ((length ( $firstactive ) < 1) || $firstactive =~ /Manual_state/ || $firstactive =~ /Manual_time_to/ || $firstactive =~ /Manual_time_from/ ) {
# # ----------------------		
			# $firstindex++;
			# next;
		# } else {
# #												print "F: $firstindex --=> $firstactive\n";
			# $coupled = 0;
		# }
		# my $secondactive = $$secondconfigptr[$secondindex];
		# $secondactive = canonize_active ( $secondactive );
# #		if (length ( $secondactive ) < 1 ) {
# # Manual_state_hack ----
		# if ((length ( $secondactive ) < 1) || $secondactive =~ /Manual_state/ || $secondactive =~ /Manual_time_to/ || $secondactive =~ /Manual_time_from/) {
# # ----------------------		

			# $secondindex++;
			# next;
		# } else {
# #												print "S: $secondindex --=> $secondactive\n";
			# $coupled = 0;
		# }
		# if ( $firstactive eq $secondactive ) {
# #												print " ==>EQUEAL\n";
			# $firstindex++;
			# $secondindex++;
			# $coupled = 1;
			# next;
		# } else {
			# last;
		# }
	# }
	# if ( $coupled ) {
		# return 1;
	# } else {
		# return 0;
	# }
# }

sub canonize_active
{
	my $active = shift;
	
	$active =~ s/#.*//;
	$active =~ s/^\s//g;
	$active =~ s/\s$//g;
	
	return $active;
}



# TODO
# remove shared subroutines
#