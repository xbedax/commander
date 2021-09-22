#!/usr/bin/perl

# performs immediate condition setting (both working and active config)
# params:
#					modules='{<module_i>}'
#					condition='<condition_string>'
# example:	direct_condition members='ZVJezirko,ZVVjezd,ZVStred,ZVLouka' condition='RDAY:2'


# Script state
#	initial implementation


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
use iconfig qw (compare_endtime compare_config);

use Data::Dumper;

my  %configphpwork = ();
my  %configphpact = ();
my  %configmain = ();
my  %configact = ();
my  @worklines = ();
my  @actlines = ();

my $mainphpconfig = "../files/promenne.php";
my $testphpconfig = "./config/files/promenne.php";
my $filehandle;	
my $configtype;
my $args = join (' ', @ARGV);

my $TESTING;
our $loglevel = 1;

our ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime ();
	$year += 1900;
	$mon += 1;
my $etime = time();


# Read configurations (main, working, current)

if ( -r $mainphpconfig) {
	open ($filehandle, "$mainphpconfig") || die "Direct condition: Can't open $mainphpconfig: $!\n";
#	$configtype = 'PHP';
} elsif ( -r $testphpconfig) {
	open ($filehandle, "$testphpconfig") || die "Direct condition: Can't open $testphpconfig: $!\n";
#	$configtype = 'PHP';
} else {
	die "Direct condition: Can't find $mainphpconfig!\n";
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
	open ( $filehandle, $configphpwork{'Global'}->{'IniterMainConfig'} ) || do  {# 							printlog (1, "Dir_Cond: Can't read lines $configtable: $!");
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

																		printlog (1, "Dir_Cond: -- Starting -- Params: $args");
#																        print "Dir_Cond: -- Starting -- Params: $args\n";

# compare working and active config
open ($filehandle, $configphpwork{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Dir_Cond: Can't read lines $configtable: $!");
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


# Parse command line parameters
my $requestedcondition;
my $modules;

foreach my $argument (@ARGV) {
	if ( $argument =~ /modules=(.+)/ ){
		$modules = $1;
		$modules =~ s/'//g;
	}
	if ( $argument =~ /.*condition=(.+)/) {
		$requestedcondition = $1;
		$requestedcondition =~ s/'//g;
	}
}

unless ( defined $modules ) {
	print "Nejsou zadány cílové moduly. Končím!";
	exit;
}
unless ( defined $requestedcondition ) {
	print "Není zadána požadovaná podmínka. Končím!";
	exit;
}

foreach my $member (split (',', $modules) ) {
	$member =~ s/'//g;
	chomp ( $member);

#																		print " $member -->> $duration \n";
	unless ( defined $configact{$member}->{Class}){
#																		printlog (1, "Plan_seq: Unknown sequence member: $member");
		print "Neexistující člen posloupnosti $member. Žádné změny nebyly provedeny.";
		exit;
	}
	unless ( defined ( $configact{$member}->{'Condition'} ) ) {
		print "Pro modul $member není možné nastavit podmínku, ignoruji.\n";
	}
		
	$configact{$member}{'Condition'} = $requestedcondition;
	$configact{$member}{'_Manual_setting_member'} = 1;
#																		print "  number of ints: $#starts \n";
		

	print "$member \n";
}



open ( $filehandle, ">" . $configphpwork{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
											print "Nelze zapisovat do pracovní konfigurace, končím!";
											exit;
											};

write_conditions ($filehandle, \@worklines, \%configact);
close $filehandle;
											
open ( $filehandle, ">" . $configphpact{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
											print "Nelze zapisovat do aktuální konfigurace, končím!";
											exit;
											};
write_conditions ($filehandle, \@actlines, \%configact);

close $filehandle;


print "\n <P> HOTOVO\n";
exit;
										

#===============================================================================
# Procedures
#===============================================================================

sub write_conditions
{
	my $confhandle = shift;												# file to write settings to
	my $configtableptr = shift;											# configuration flat array
	my $configstructptr = shift;										# configuration tree
	
	my $cursection = "";
	my $insection = 0;
	my $deletemanual = 0;

	foreach my $line (@$configtableptr) {
#												print "Read-->$line\n";
		my $activeline = $line;
		$activeline =~ s/#.*//;
		if( $activeline =~ /^\s*\[{1,2}([^\]]+)\]{1,2}/ ){						# delimiter
#																		print "Delimiter found\n";
			if ( $activeline =~ /^\s*\[(?!<\[)([^\[\]]+)\](?!\])/ ) {	# section
				$cursection = $1;
#																		print "Section found: $cursection \n";
				$deletemanual = 0;
# Delete expired man state										
				if ( defined ($$configstructptr{$cursection}{'Manual_state'} ) ) {
					unless ( compare_endtime( $$configstructptr{$cursection}{'Manual_time_to'} ) ) {
						$deletemanual = 1;
					}
				}
				if( defined ($$configstructptr{$cursection}{'_Manual_setting_member'} ) ) {
#																		print "Target section found\n";
					$insection = 1;
				} else {
					$insection = 0;
				}
			} else {
				$insection = 0;
			}
		} else {
			if ( $insection ) {
				if ( $activeline =~ /Condition\s*=/ ) {
					$line =~ s/(Condition\s*=)[^#\n]*(.*)/$1$requestedcondition$2/;
				}
			}
		}
		if ( $deletemanual ) {
			unless ($line =~ /Manual_state/ || $line =~ /Manual_time_to/ || $line =~ /Manual_time_from/ ) {
				print $confhandle $line;
			}
		} else {
			print $confhandle $line;
		}
	}
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





