#!/usr/bin/perl

# performs syntax and (partialy) semantic check of commander config files
#	- verifies presence of all necessary attributes
#	- scans for duplicities
#	- checks values
#	- looks for references

# example:	config_checker ... checks [ConfigTable] only
# example:	config_checker module='ZVStred' ... checks the specified module only


# Script state
#	initial release
#	15.8.2021
#		manual_state_from 	incorporated




use IO::Handle;
use IO::Socket;
use strict;
use warnings;
use Module::Runtime qw(
        $module_name_rx is_module_name check_module_name
        module_notional_filename require_module);

use lib '.';
use iconfig;
use Data::Dumper;

my  %configmain = ();
my  %configtab = ();
my  %gwtab = ();
our %registered_protocols = ();
my  %thtcomp = ( 'Term' => '<dnumber>', 'Hum' => '<dnumber>', 'Dew' => '<dnumber>', );

my %classmandatory =	(
					'Qport' => { 	'Class' => '<enum:class>',
									'Proto' => '<enum:protocols>',
									'Gateway' => '<enum:gateways>',
									'Bus_address' => '<address>',
									'Port_num' => '<pnumber>',
									'Req_state' => '<enum:state>',
									'Default_state' => '<enum:state>',
									'Condition'=> '<condition>',
									'Log' => '<logcond>'
								},
					'Qinp' =>	{	'Class' => '<enum:class>',
									'Proto' => '<enum:protocols>',
									'Gateway' => '<enum:gateways>',
									'Bus_address' => '<address>',
									'Port_num' => '<pnumber>',
									'Log' => '<logcond>'
								},
					'Qctr' =>	{	'Class' => '<enum:class>',
									'Proto' => '<enum:protocols>',
									'Gateway' => '<enum:gateways>',
									'Bus_address' => '<address>',
									'Port_num' => '<pnumber>',
									'Clear_read' => '',
									'Log' => '<logcond>'
								},
					'Qterm' =>	{	'Class' => '<enum:class>',
									'Proto' => '<enum:protocols>',
									'Gateway' => '<enum:gateways>',
									'Bus_address' => '<address>',
									'Port_num' => '<pnumber>',
									'Log' => '<logcond>'
								},

					'THT' =>	{	'Class' => '<enum:class>',
									'Proto' => '<enum:protocols>',
									'Gateway' => '<enum:gateways>',
									'Bus_address' => '<address>',
									'Log' => '<logcond>'
								},
					'Qpair' =>	{	'Class' => '<enum:class>',
									'Port_Up' => '<reference>',
									'Port_Down' => '<reference>',
									'Req_state' => '<enum:state>',
									'Default_state' => '<enum:manstate>',
									'Log' => '<logcond>'
									
								}
						);

my %classoptional =		( 	
					'Qport' =>	{ 	'Manual_state' => '<enum:manstate>',
									'Manual_time_to' => '<datetime>',
									'Manual_time_from' => '<datetime>',
								},
					'Qinp' =>	{		
								},
					'Qctr' =>	{		
								},
					'Qterm' =>	{		
								},
					'THT' =>	{	'Component' => '<enum:thtcomponent>',
								},
					'Qpair' =>	{	'Manual_state' => '<enum:manstate>',
									'Manual_time_to' => '<datetime>',
									'Manual_time_from' => '<datetime>',
								}
						);

my %statemandatory =	(
					'ON' =>		{	
								},
					'OFF' =>	{	
								},
								
					'TIME' =>	{	'State_from' => '<time>',
									'State_to' => '<time>'
								},
					'HEAT' =>	{	'Temp_min' => '<wnumber>',
									'Temp_hyst' => '<pnumber>',
									'Meter' => '<reference>',
									'Frequency' => '<pnumber>'
									
								},
					'QPmember' =>
								{	
								},
					'STEPVENT' =>
								{	'Temp_max' => '<wnumber>',
									'Temp_hyst' => '<pnumber>',
									'Step_count' => '<pnumber>',
									'Step_duration' => '<pnumber>',
									'Meter' => '<reference>',
									'Frequency' => '<pnumber>'
								},
					'STEPHUMVENT' => 
								{	'Temp_max' => '<wnumber>',
									'Temp_hyst' => '<pnumber>',
									'Hum_max' => '<pnumber>',
									'Hum_hyst' => '<pnumber>',
									'Hvent_mintemp' => '<wnumber>',
									'Step_count' => '<pnumber>',
									'Step_duration' => '<pnumber>',
									'Tmeter' => '<reference>',
									'Hmeter' => '<reference>',
									'Frequency' => '<pnumber>'
								},
					'TIMEI' =>	{	'State_on_int' => '{<time>-<time>}'
								},
					'PULSE' =>	{	'State_from' => '<time>',
									'State_to' => '<time>',
									'Frequency' => '<pnumber>'
								},
					'DPULSE' =>	{	'Duration' => '<pnumber>',
									'Frequency' => '<pnumber>'
								},
					'SPILL' =>	{	'State_on_int' => '{<time>-<time>}',
									'Spill_len' => '<pnumber>',
									'Spill_pause' => '<pnumber>',
									'Meter' => '<reference>'
								}
						);

my %manstate =	(
					'ON' =>		[	
								],
					'OFF' =>	[	
								],
								
					'TIME' =>	[	
								],
					'HEAT' =>	[										
								],
					'QPmember' =>
								[	
								],
					'STEPVENT' =>
								[	'<pnumber>',
								],
					'STEPHUMVENT' => 
								[	'<pnumber>',
								],
					'TIMEI' =>	[	
								],
					'PULSE' =>	[	
								],
					'DPULSE' =>	[	
								],
					'SPILL' =>	[	
								]
						);


my $mainconfig = "./config.local";
my $filehandle;	
my $evaluation;
my $moduletocheck;
my $attributetocheck;

my $args = join (' ', @ARGV);
our $tempfolder;

# Parse command line parameters
foreach my $argument (@ARGV) {
	if ( $argument =~ /module=(.+)/ ){
		$moduletocheck = $1;
		$moduletocheck =~ s/'//g;
	}
		if ( $argument =~ /attribute=(.+)/ ){
		$attributetocheck = $1;
		$attributetocheck =~ s/'//g;
	}

}
# Load protocols 
my $openresult = opendir (DIR, './protocols') or do {
	print "Unable to open protocols directory";
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
 
# Read main configuration
if ( -r $mainconfig) {
	open ($filehandle, "$mainconfig") || die "Checker: Can't open $mainconfig: $!\n";
#	$configtype = 'PHP';
} else {
	die "Checker: Can't find $mainconfig!\n";
}
unless ( read_config ($filehandle, \%configmain) ) {
	print "Poškozená  konfigurace!\n";
}
close $filehandle;
# Load gateways
if ( -r $configmain{'Comm'}{'GatewayTable'}) {
	open ($filehandle, "$configmain{'Comm'}{'GatewayTable'}") || die "INITER: Can't open $filehandle: $!\n";
} else {
	die "INITER: Can't find $configmain{'Comm'}{'GatewayTable'}!\n";
}

read_config ($filehandle, \%gwtab);
close ($filehandle);


open ($filehandle, $configmain{'Global'}->{'ConfigTable'}) || do {# 							printlog (1, "Plan_seq: Can't read lines $configtable: $!");
											print "Nelze otevřít aktivní konfiguraci, končím!";
											exit;
											};

# Read config table and check for duplicities
my @supersections;
my $lineidx = 0;
my $section;
while (<$filehandle>) {
	
	$lineidx++;
	chomp;
	s/#.*//;
#	s/\s//g;
	if (/^\s*\[\[([\w-]+)\]\].*/) {
		my $supersection = $1;
		foreach my $knownsupersection ( @supersections ) {
			if ( $supersection == $knownsupersection ) {
				$evaluation .= "|$supersection($lineidx)-ERR:DUPL";
			}
		}
		push ( @supersections, $supersection );
		next;
	}
	if (/^\s*\[([\w-]+)\].*/) {
		$section = $1;
		if ( defined (	$configtab{$section} ) ) {
			$evaluation .= "|$section($lineidx)-ERR:DUPL";
		}
	}
	if (/^\W*([\w\d:]+)=\s*(\S.*)/) {
		my $keyword = $1;
		my $value = $2 ;
		chomp $value;
		if ( defined (	$configtab{$section}{$keyword} ) ) {
			$evaluation .= "|$section($lineidx)-ERR:DUPL";
		}
		$configtab{ $section } {$keyword}  = $value;
		}
}

close $filehandle;


# Look for module definitions 
my @modulestocheck = ();

if ( defined $moduletocheck ) {
	push ( @modulestocheck, $moduletocheck );
} else {
	foreach my $module (  keys %configtab ) {
		push ( @modulestocheck, $module );
	}
}

foreach my $module ( @modulestocheck ) {
																		print "\n$module\n===============\n";
	unless ( defined ( $configtab{$module}{'Class'} ) ) {
		$evaluation .= "|$module(Class)-'ERR:MISS";
		next;
	}
	# Check for module definition completeness (mandatory attributes)
	my $class = $configtab{$module}{'Class'};
	foreach my $attribute ( keys %{$classmandatory{$class}} ) {
		unless ( defined ( $configtab{$module}{$attribute} ) ) {
			$evaluation .= "|$module($attribute)-'ERR:MISS";
			next;
		}
																		print " - $attribute (Clss): $configtab{$module}{$attribute} -> $classmandatory{$class}{$attribute}";
		my $result = check_value ($configtab{$module}{$attribute}, $classmandatory{$class}{$attribute}, $configtab{$module}{'Req_state'} );
																		print " --> $result\n";
		$evaluation .= "|$module($attribute)-$result";
	}
	my $state = '';
	if ( defined ( $configtab{$module}{'Req_state'} ) ) {
		$state = $configtab{$module}{'Req_state'};
	}
	foreach my $attribute ( keys %{$statemandatory{$state}} ) {
		unless ( defined ( $configtab{$module}{$attribute} ) ) {
			$evaluation .= "|$module($attribute)-'ERR:MISS";
			next;
		}
																		print " - $attribute (Mand): $configtab{$module}{$attribute} -> $statemandatory{$state}{$attribute}";
		my $result = check_value ($configtab{$module}{$attribute}, $statemandatory{$state}{$attribute}, $configtab{$module}{'Req_state'} );
																		print " --> $result\n";
		$evaluation .= "|$module($attribute)-$result";
	}
	# Chech for optional attributes, identify would-be unknown attributes
	foreach my $attribute ( keys %{$configtab{$module}} ) {
		if ( defined ( $classmandatory{$class}{$attribute} ) ) {
			next;
		}
		if ( defined ( $statemandatory{$state}{$attribute} ) ) {
			next;
		}
		if ( defined ( $classoptional{$class}{$attribute} ) ) {
																		print " - $attribute (Opti): $configtab{$module}{$attribute} -> $classoptional{$class}{$attribute}";
			my $result .= check_value ( $configtab{$module}{$attribute}, $classoptional{$class}{$attribute}, $configtab{$module}{'Req_state'} );
																		print " --> $result\n";
			$evaluation .= "|$module($attribute)-$result";
			next;
		}
																		print " - $attribute: Unknown!\n";
			$evaluation .= "|$module($attribute)-WARN:UNKNOWN";
	}
		
}
		
print "\n\nEvaluation: $evaluation \n\n";

$evaluation =~ s/\|[^\|]+-(OK|MAYBE)(?=\|)//g;
$evaluation =~ s/\|[^\|]+-(OK|MAYBE)$//g;
print "\n\nErrors: $evaluation\n";


print "\n <P> HOTOVO\n";
exit;
										

#===============================================================================
# Procedures
#===============================================================================

sub check_value2
{
	my $value = shift;
	my $format = shift;
	my $parsedpartptr = shift;
	
	my @values;
	my $result;
	
	while ( length ( $format ) > 0 ) {
		$format =~ /^([^<\[]+)/;											# constant string
		if ( defined ( $1 ) ){
			unless ( $value =~ /^$1/ ) {
				return 'ERR:BAD_FORMAT';
			}
			$value =~ s/^$1//;
			$format =~ s/^([^<\[]+)//;
		}
				
		if ( $format =~ /^([^\[]*)\[(.*)\](.*)/ ) {											#optional part
			my $format1 = $1 . $3;
			my $format2 = $1 . $2 . $3;
			my $result1 = check_value ( $value, $format1 );
			my $result2 = check_value ( $value, $format2 );
			if ( $result1 eq 'OK' || $result2 eq 'OK' ) {
				return 'OK';
			} 
			return $result1;
		}
		
		if ( $format =~ /^{ / ) {											#list of values
			$format =~ s/^{//;
			$format =~ s/}$//;
			my @subvalues = split ('|', $value );
			foreach my $subvalue ( @subvalues ) {
				$result .= check_value ( $subvalue, $format );
			} 
			return $result;
		}
		
		if ( $format =~ /^(<[^>]+>)-(<[^>]+>)$/ ) {							#interval
			my ($ifrom, $ito) = split ( '-', $value );
			my $result .= check_value ( $ifrom, $1 ) .  check_value ( $ito, $2 );
			return $result;
		}
			 
		if ( $format =~ /<pnumber>/ ) {										#positive number
			if ( $value =~ /^\s*\d+\s*$/ ) {
				return 'OK';
			} else {
				return 'ERR:NOPNUM';
			}
		}
		if ( $format =~ /<wnumber>/ ) {										#whole number
			if ( $value =~ /^\s*-{0,1}\d+\s*$/ ) {
				return 'OK';
			} else {
				return 'ERR:NOWNUM';
			}
		}	
			
		if ( $format =~ /<time>/ ) {										#time
			return check_time ( $value );
		}	
		if ( $format =~ /<reference>/ ) {									#reference
			return check_reference ( $value );
		}	
		if ( $format =~ /<enum:.*>/ ){										#enum
			return check_enum ( $value, $format );
		}
		if ( $format =~ /<condition>/ ) {									#condition
			return check_condition ( $value );
		}	
			if ( $format =~ /<address>/ ) {									#address
			return check_address ( $value );
		}	
	}		
	return 'MAYBE';
}


sub check_value
{
	my $value = shift;
	my $format = shift;
	my $class = shift;
	
	my @values;
	my $result;
	
	

	
	if ( $format =~ /^(<[^>]+>)-(<[^>]+>)$/ ) {							#interval
		my ($ifrom, $ito) = split ( '-', $value );
		my $result .= check_value ( $ifrom, $1 ) .  check_value ( $ito, $2 );
		return $result;
	}

	
	if ( $format =~ /^{ / ) {											#list of values
		$format =~ s/^{//;
		$format =~ s/}$//;
		my @subvalues = split ('|', $value );
		foreach my $subvalue ( @subvalues ) {
			$result .= check_value ( $subvalue, $format );
		} 
		return $result;
	}
	
	if ( $format =~ /^(<[^>]+>)-(<[^>]+>)$/ ) {							#interval
		my ($ifrom, $ito) = split ( '-', $value );
		my $result .= check_value ( $ifrom, $1 ) .  check_value ( $ito, $2 );
		return $result;
	}
		 
	if ( $format =~ /<pnumber>/ ) {										#positive number
		if ( $value =~ /^\s*\d+\s*$/ ) {
			return 'OK';
		} else {
			return 'ERR:NOPNUM';
		}
	}
	if ( $format =~ /<wnumber>/ ) {										#whole number
		if ( $value =~ /^\s*-{0,1}\d+\s*$/ ) {
			return 'OK';
		} else {
			return 'ERR:NOWNUM';
		}
	}	
		
	if ( $format =~ /<time>/ ) {										#time
		return check_time ( $value );
	}	
	if ( $format =~ /<reference>/ ) {									#reference
		return check_reference ( $value );
	}	
	if ( $format =~ /<enum:.*>/ ){										#enum
		return check_enum ( $value, $format, $class );
	}
	if ( $format =~ /<condition>/ ) {									#condition
		return check_condition ( $value );
	}	
	if ( $format =~ /<address>/ ) {										#address
		return check_address ( $value );
	}	
	if ( $format =~ /<logcond>/ ) {										#log condition
		return check_logcond ( $value );
	}	

		
	return 'MAYBE';
}

sub check_date
{
	my $input = shift;
	
	if ( $input =~ /^\s*(\d\d).(\d\d).(\d{4})\s*$/ ) {
		my $day = $1;
		my $month = $2;
		my $year = $3;
		my @mday = (31,29,31,30,31,30,31,31,30,31,30,31);
		
		if ( $year % 4 == 0) {
			unless ( ( $year % 100 != 0 ) || ($year % 400 == 0 ) )  {
				unless ( $day <= 28 ) {
					return 'ERR:BAD_DATUM';
				}
			} else {
				unless  ( $day <= 29 ) {
					return  'ERR:BAD_DATUM';
				}
			}
		}
		unless ( $month <= 12 ) {
			return 'ERR:BAD_DATUM';
		}
		unless ( $day <= $mday[$month] ) {
			return 'ERR:BAD_DATUM';
		}		
		return 'OK';
	} else {
		return 'ERR:BAD_DATUM';
	}
}

sub check_time
{
	my $input = shift;
	if ( $input =~ /^\s*(\d)(\d)(\d)(\d)\s*$/ ) {
		if ( ($1 > 2 ) || ($3 > 5 ) ) {
			return 'ERR:BAD_TIME';
		}
		if ( ( $1 == 2 ) && ( $2 > 3 ) ) {
			return 'ERR:BAD_TIME';
		}
		return 'OK';
	}
	return 'ERR:BAD_TIME';
}
 
sub check_reference
{
	my $input = shift;
	chomp $input;
	
																			print " ...Looking for $input ... ";
	
	if ( defined $configtab{$input} ) {
		return 'OK';
	
	}
	foreach my $module ( keys %configtab ) {
		if ( $module =~ /^$input$/i ) {
			return 'ERR:REF_CASE';
		}
	}
	return 'ERR:REF_UNKNOWN';
}

sub check_enum
{
	my $input = shift;
	my $format = shift;
	my $class = shift;
	
	if ( $format =~ /^<enum:([^>]+)>/ ) {
		
		if ( $1 eq 'class' ) {
			if ( defined ( $classmandatory{$input} ) ) {
				return 'OK';
			} else {
				return 'ERR:ENUM_BADCLASS';
			}
		}
		if ( $1 eq 'state' ) {
			if ( defined ( $statemandatory{$input} ) ) {
				return 'OK';
			} else {
				return 'ERR:ENUM_BADSTATE';
			}
		}
		if ( $1 eq 'manstate' ) {
			if ( defined ( $statemandatory{$input} ) ) {
				return 'OK';
			}
			if ( defined ( $manstate{$class} ) ) {
				foreach my $manvalue (@{$manstate{$class}}) {
					
																		print "Checking $manvalue\n";
					
					if ( $manvalue =~ /</ ) {
						if( 'OK' eq check_value ($input, $manvalue, $class ) ) {;
							return 'OK';
						}
					} else {
						if ( $manvalue eq $input ) {
							return 'OK';
						}
					}
				}
			}
			return 'ERR:ENUM_BADSTATE';
		}
		
		if ( $1 eq 'protocols' ) {
			if ( defined ( $registered_protocols{$input} ) ) {
				return 'OK';
			} else {
				return 'ERR:ENUM_BADPROTOCOL';
			}
		}
		if ( $1 eq 'gateways' ) {
			if ( defined ( $gwtab{$input} ) ) {
				return 'OK';
			} else {
				return 'ERR:ENUM_BADGATEWAY';
			}
		}
		if ( $1 eq 'thtcomponent' ) {
			if ( defined ( $thtcomp{$input} ) ) {
				return 'OK';
			} else {
				return 'ERR:ENUM_BADCOMPONENT';
			}
		}

		
	}
	return 'ERR:ENUM_UNKNOWN';
}
			
sub check_condition
{
	my $condition = shift;
	
	my $conditionmet = 1;
#																		printlog (5, " Evaluating: $condition");
	if( $condition =~ /^EXP:/ ) {
		$condition =~ s/^EXP:\s*//;
		my @parenthesis;
		while ( $condition =~ /\(([^\(^\)]*)\)/ ){
			push @parenthesis, $1;
#																		print ">$level<    Pushed: $1 - " . $#parenthesis . "\n";
			my $index = '___' . $#parenthesis . '___';
			$condition =~ s/\([^\(^\)]*\)/$index/;
		}
		if ( $condition =~ /[\(\)]/ ) {
			return 'ERR:PARENTHESIS';
		} 
#																		print ">$level<       Substitued: $condition\n";
		my @orparts = split ( ' OR ', $condition );
		$conditionmet = 0;
		foreach my $orpart (@orparts) {
#																		print ">$level<            Orpart: $orpart\n";
			my @andparts = split ( ' AND ', $orpart );
			foreach my $andpart ( @andparts ) {
				if ( $andpart =~ /^\s*NOT/ ) {
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
				my $result = check_condition( $andpart  );
				if ( $result =~ /ERR:/ ) {
					return $result;
				}
			}
		}
		return 'OK';
	}else{
		if ( $condition eq 'NONE' ) {
			return 'OK';
		}
	
		if( $condition =~ /WDAY:[1-7;]+/ ) {
			$condition =~ /WDAY:([^;]*)/;
			my @condays = split (';', $1);
			foreach my $cday (@condays) {
				if ($cday < 1 || $cday > 7 ) {
					return 'ERR:BADWDAY';
				} else {
					return 'OK';
				}
			}
		}
		if( $condition =~ /RDAY:/i ) {
			$condition =~ /RDAY:([^;]*)/i;
			if ( $1 < 1 ) {
				return 'ERR:COND_BADRDAY';
			} else {
				return 'OK';
			}
		}
		if( $condition =~ /DATE:/ ) {
			$condition =~ /DATE:([^;]*)/;
			my $checkres = check_date ( $1);
			if ( $checkres =~ /ERR:/ ) {
				return $checkres;
			} else {
				return 'OK';
			}
		}
		if( $condition =~ /(&.*)/ ) {
#			$condition =~ /(&.*)/;
			my $checkmodul = $1;
			my @condparts = split( ';', $1);
			foreach my $condpart (@condparts) {
				my $relname = $condpart;
				my $relstate = $condpart;
#																			print "Condpart : $condpart\n";
				$relname =~ /^&([^><:=]+)/;
				my $relres = check_reference ( $1 );
				if ( $relres =~ /ERR:/ ) {
					return $relres;
				}
#																			print "Read condition state $relname: $ccond\n";
				$relstate =~ s/[^:=><]+[:=><]//;				#tady odstranit : az Leos naimplementuje = v podmince
				my $stateres = check_state ( $relstate );
				if ( $stateres =~ /ERR:/ ) {
					return $stateres;
					
				}
			}
			return 'OK';
		}	
	}
																			printlog  (5, "Evaluated: $condition =>$conditionmet " );
	return 'ERR:COND_UNKNOWN';
}
			
sub check_state
{
	my $input = shift;
	
	if ( ( $input =~ /^\d+$/ ) || ( $input eq 'OFF' ) || ( $input eq 'ON' ) ) {
		return 'OK';
	}
	return 'ERR:STATE_BAD';
}

sub check_logcond
{
	my $input = shift;
	
	if  ( $input =~ /^[012]+$/ ) {
		return 'OK';
	}
	if  ( $input =~ /^[012],\d+$/ ) {
		return 'OK';
	}

	return 'ERR:LOG_BAD';
}


sub check_address
{
	my $input = shift;
	
	if ( ( $input =~ /^\d$/ ) || ( $input =~ /^\w$/ ) ) {
		return 'OK';
	}
	return 'ERR:STATE_ADDRESS';
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



# TODO
# global lock to avoid interference with main program
# 





