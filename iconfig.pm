#!/usr/bin/perl


# 1.01.00
#	first release 
# 1.02.00
#	added curstep handling
# 1.03.00
#	added last states handling
#	long running commands resolved 
# 1.03.01
#	removed white space clearing from read_config
#	changed keyword=value pair handling in read_config to facilitate reading of values containing white spaces
# 1.03.02
#	added maxtotallogsize a maxrunlogsize limits
# 1.03.03
#	allowed "-" to be part of section name
# 1.03.04
#	compare_endtime moved form initer

#package initer;
@EXPORT = qw ( printlog read_config read_php_config );
@EXPORT_OK = qw ( write_curstep get_curstep read_last_states write_last_states compare_endtime write_manual compare_config);

use warnings;
use strict;
use Time::Local;
use Time::Seconds;
use POSIX ":sys_wait_h";
#use Data::Dumper;
use base 'Exporter';
#use Encode;
#use utf8;
use IO::Handle;

my $maxrunlog = 100000;
my $maxtotallog = 10000000;
my $runlogsize = 0;

our $VERSION = "1.03.04";
# Writes log record if record severity is greater than loglevel
sub printlog 
{
	my $severity = shift;
	my $text = shift;
	
	my $textout = "";
	
	if ( defined ($main::logprefix) ) {
		$textout = $main::logprefix;
	}
	if ( defined ($main::loglocal) ) {
		$textout .= localtime . " $text\n";
	} else {
		$textout .= time . " $text\n";
	}

	
#	if ( defined ($main::consoleencoding)) {
#		$text = encode($main::consoleencoding, $text );
#	}

	if ($severity > $main::loglevel) {
		return 1;
	}
	if ($main::logto eq "file") {
		my $logsize;
		unless	($logsize = -s $main::logfile ) {
			$logsize = 0;
		}
		if ( defined ( $main::maxtotallogsize ) ) {
			$maxtotallog = $main::maxtotallogsize;
		}
		if ( defined ( $main::maxrunlogsize ) ) {
			$maxrunlog = $main::maxrunlogsize;
		}
		if ( $maxrunlog < $runlogsize ) {
																		print "Runlog exceeded\n";
			return;
		}
		if ( $maxtotallog  < $logsize ) {
																		print "Totallog exceeded\n";				
			return;
		}
					
		if ( ( $maxrunlog - 70 ) < $runlogsize ) {
			$textout = "ERROR: Max total log size exceeded!";
		}
		if ( ( $maxtotallog - 70 ) < $logsize ) {
			$textout = "ERROR: Max log size exceeded!";
		}
			
		open (LOG, ">>", $main::logfile);
		print LOG $textout;
		close LOG;
		$runlogsize = $runlogsize + length ( $textout );
		return 1;
	}
 
	print $textout;
	return;
	
}

# Reads initer module configuration
sub read_config
{
	my $inihandler = shift;
	my $confstructptr = shift;
	my $section;

	while (<$inihandler>) {
		chomp;
		s/#.*//;
#		s/\s//g;
		if (/^\s*\[\[([\w-]+)\]\].*/) {
#					$supersection = $1;
					next;
		}
		if (/^\s*\[([\w-]+)\].*/) {
					$section = $1;
		}
		if (/^\W*([\w\d:]+)=\s*(\S.*)/) {
			my $keyword = $1;
			my $value = $2 ;
			chomp $value;
			$$confstructptr{ $section } {$keyword}  = $value;
		}
	}
	return 1;
}

# Scans main PHP UI config for main and ACTIVE or WORKING initer configuration filename
#	the result injects into configuration hash $$confstructptr{ 'Global' }{ 'ConfigTable' }, $$confstructptr{ 'Global' }{ 'IniterMainConfig' }
sub read_php_config
{
	my $inihandler = shift;
	my $confstructptr = shift;
	my $conftype = shift;

	my $conffound = 0;
	my $mainfound = 0;
	while (<$inihandler>) {
		chomp;
#		s/\/\/.*//;		
		
		if (( $conftype eq 'WORKING') && /workingConfiguration\s*=\s*['"]([^'"]*)['"].*/) {
			$$confstructptr{ 'Global' }{ 'ConfigTable' }  = $1;
			$conffound = 1;
		}
		if (( $conftype eq 'ACTIVE') && /currentConfiguration\s*=\s*['"]([^'"]*)['"].*/) {
			$$confstructptr{ 'Global' }{ 'ConfigTable' }  = $1;
			$conffound = 1;
		}
		if ( /initerconfig\s*=\s*['"]([^'"]*)['"].*/) {
			$$confstructptr{ 'Global' }{ 'IniterMainConfig' }  = $1;			
			$mainfound = 1;
		}
	}
	return ($conffound && $mainfound);
}	
# Reads stepper current step from <module_name>.<steppersuffix> file
sub get_curstep
{
	my $step_name = shift;
	my $step_file = $main::tempfolder . $step_name . $main::stepsuffix;
	
	if ( open (STF, "$step_file")  ) {
		my $cstep = <STF>;
		chomp $cstep;
		close STF;
#																		print  "		Step read: $cstep \n";
		if ( $cstep >= 0) {
			return $cstep;
		}
	} 
	return $main::resetstep;
}
# Writes stepper current step into <module_name>.<steppersuffix> file
sub write_curstep
{
	my $step_name = shift;
	my $step_num = shift;
	my $step_file = $main::tempfolder . $step_name . $main::stepsuffix;
	
#																		print  "		Step written: $step_num \n";	
	if ( open (STF, ">$step_file")  ) {
		print STF "$step_num";
		close STF;
		return 1;
	} 
	return $main::resetstep;
}


# Reads homestat table into statetablehdl hash of the form:
#	modulename -> LastState
#	              LastTime (YYYY:MM:DD:hh:mm)
#	              CommandEnd (YYYY:MM:DD:hh:mm)
sub read_last_states
{
	my $statefilehdl = shift;
	my $statetableptr = shift;
	my $checktime;
	
	while ( <$statefilehdl> ) {
		unless ($_ =~ /=/ ) {
			next;
		}
#		print $_ ;
		chomp $_;
		my ($modulename , $moduleinfo) = split ( '=', $_ );
		my @infoparts = split ( ';', $moduleinfo);;
#		my ($modulestate, $statetime, $commandend) = 
		$modulename =~ s/ //;
		foreach my $part (@infoparts) {
			$part =~ s/^\s*//;
		}
		
		if (defined $$statetableptr{$modulename} ) {
			$$statetableptr{$modulename}{'LastState'} = $infoparts[0];
			$$statetableptr{$modulename}{'LastTime'} = $infoparts[1];
			foreach my $part (@infoparts) {
				if ( $part =~ /CE:(.+)/ ) {
					$$statetableptr{$modulename}{'CommandEnd'} = $1;
					my ($csec,$cmin,$chour,$cmday,$cmon,$cyear,$cwday,$cyday,$cisdst) = localtime (time);
					$cyear += 1900;
					$cmon += 1;
					my $CommandEnd = sprintf ("%02d",$cyear) . ':' . sprintf ("%02d", $cmon) . ':' . sprintf ("%02d", $cmday) . ':' . sprintf ("%02d", $chour) . ':' . sprintf ("%02d",$cmin) . ':' . sprintf ("%02d",$csec);
					if ($CommandEnd gt $$statetableptr{$modulename}{'CommandEnd'} ) {
						undef $$statetableptr{$modulename}{'CommandEnd'};
					}
				}	
				
			}
		}
		if ( $modulename =~ /_Check_/ ) {
			$checktime = $moduleinfo;
		}
	}
	foreach my $module (keys %$statetableptr) {
		unless ( defined ( $$statetableptr{$module}{'LastState'} ) ){
			$$statetableptr{$module}{'LastState'} = 'ERROR:MISSING';
		}
	}
	chomp $checktime;
	$checktime =~ s/^\s*//;
	return $checktime;
}

# Writes homestat table based on statetableptr hash of the form:
#	modulename -> LastState
#	              LastTime (YYYY:MM:DD:hh:mm)
#	              CommandEnd (YYYY:MM:DD:hh:mm)

sub write_last_states
{
	my $stattableptr = shift;
	my $stattable = shift;
	my $curtimestring = shift;
	my $stattablehdl;
	
	open ($stattablehdl, ">$stattable");
	
	unless (  $stattablehdl  ) {
																		printlog (1, "Unable to write to stattable $stattable - $!" );
		return 0;
	}

#	my $ldate = $year . ':' . sprintf( "%02d", $mon) . ':' . sprintf( "%02d", $mday) . ":" . sprintf( "%02d", $hour) . ":" . sprintf( "%02d", $min);
	print $stattablehdl "_Check_ =	$curtimestring\n";

	foreach my $key (keys %$stattableptr) {
		print $stattablehdl "$key=";
		unless ( ! (defined ( $$stattableptr{ $key }{'CurState'} )) || $$stattableptr{ $key }{'CurState'} =~ /ERROR/ ) {
			chomp $$stattableptr{ $key }{'CurState'};
			print $stattablehdl "$$stattableptr{ $key }{'CurState'};$curtimestring";
		} else {
			unless ( defined ( $$stattableptr{ $key }{'LastTime'} ) ) {
				$$stattableptr{ $key }{'LastTime'} = "1900:01:01:01:01";
			}
			print $stattablehdl "$$stattableptr{ $key }{'LastState'};$$stattableptr{ $key }{'LastTime'}";
		}
		if ( defined $$stattableptr{ $key }{'CommandEnd'} ) {
			if ( $curtimestring lt $$stattableptr{ $key }{'CommandEnd'} ) {
				print $stattablehdl ";CE:$$stattableptr{ $key }{'CommandEnd'}";
			}
		}
		print $stattablehdl "\n";
	}
	close $stattablehdl;
	return 1;
}

# writes manual settigns to config table specified by handle
# seeks any module identified by Manula_settings_member = 1
# expects Manual_state and Manual_time_to to be defined, Manual_time_from is optional
sub write_manual
{
	my $confhandle = shift;												# file to write settings to
	my $configtableptr = shift;											# configuration flat array
	my $configstructptr = shift;										# configuration tree
	
	my $cursection = "";
#	my $insection = 0;
	my @linebuff = ();
	my $statefound = 0;
	my $timetofound = 0;
	my $timefromfound = 0;
	my $deletemanual = 0;
	my $prevsection;
	my $linescount = scalar(@$configtableptr) ;
	for my $i (0..$linescount) {
#																		print "$i / $linescount\n";
		my $line;
		if ( $i < $linescount ) {
			$line = $$configtableptr[$i];
		} else {
			$line = " ";
		}
		my $activeline = $line;
		$activeline =~ s/#.*//;
		if ( ( $activeline =~ /^\s*\[{1,2}([^\]]+)\]{1,2}/ ) || ( $i == $linescount ) ) {						# delimiter
#																		print "Delimiter found\n";
			$prevsection = $cursection;
			$cursection = "";
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
# Force deleting the manualstate settings if CLEAR requested
					if ( $$configstructptr{$cursection}{'Manual_state'} =~ /CLEAR/i ) {
						$deletemanual = 1;
					} else {
#						$insection = 1;
						$deletemanual = 0;
					}
				}
			}
			if ( defined ($$configstructptr{$prevsection}{'_Manual_setting_member'} ) && not ( $$configstructptr{$prevsection}{'Manual_state'} =~ /CLEAR/ ) ) {
#																		print "Target section leaved\n";
				
				unless ( $statefound ) {
#																		print "Adding Manual_state->$$configstructptr{$prevsection}{'Manual_state'}<--\n";
					print $confhandle "Manual_state=$$configstructptr{$prevsection}{'Manual_state'}\n";
				}
				unless ( $timetofound ) {
#																		print "Adding Manual_time_to->$$configstructptr{$prevsection}{'Manual_time_to'}<--\n";
					print $confhandle "Manual_time_to=$$configstructptr{$prevsection}{'Manual_time_to'}\n";
				}
				unless ( $timefromfound ) {
					if ( defined ( $$configstructptr{$prevsection}{'Manual_time_from'} ) ) {
#																		print "Adding Manual_time_from->$$configstructptr{$prevsection}{'Manual_time_from'}<--\n";
						print $confhandle "Manual_time_from=$$configstructptr{$prevsection}{'Manual_time_from'}\n";
					}
				}
				while (defined (my $bufline = shift  @linebuff))  {
#																		print "Writting from buffer->$bufline\n";
					print $confhandle $bufline;
				}
			}
			$statefound = $timetofound = $timefromfound = 0;
		}
		if( defined ($$configstructptr{$cursection}{'_Manual_setting_member'} ) && not ( $$configstructptr{$cursection}{'Manual_state'} =~ /CLEAR/ ) ) {
			if( $activeline =~ /Manual_time_to/ ) {
				my $newtimeto = $$configstructptr{$cursection}{'Manual_time_to'};
#																		print "Updating timeto-->$newtimeto\n";
				$line =~ s/=.*/=$newtimeto/;
				$timetofound = 1;
			} 
			if( $activeline =~ /Manual_time_from/ ) {
				if ( defined ( $$configstructptr{$cursection}{'Manual_time_from'} ) ) {
					my $newtimefrom = $$configstructptr{$cursection}{'Manual_time_from'};
#																		print "Updating timeto-->$newtimefrom\n";
					$line =~ s/=.*/=$newtimefrom/;
					$timefromfound = 1;
				} else {
					next;
				}
			} 

			if ( $activeline =~ /Manual_state/ ) {
				my $newstate = $$configstructptr{$cursection}{'Manual_state'};
#																		print "Updating manstate-->$newstate\n";
				$line =~ s/=.*/=$newstate/;
				$statefound = 1;
			}
			$activeline =~ s/\s//g;
#												print "actline--|$activeline|--\n";
			if ( length ( $activeline ) > 0 ) {
				while (defined (my $bufline = shift  @linebuff ) )  {
#																		print "Writting from buff->$bufline\n";
					print $confhandle $bufline;
				}
			} else {
				push ( @linebuff, $line );
#																		print "Buffering-->$line\n";
				next;
			}
		}
		unless ( $i == $linescount ) {										
#																		print "Writting -->$line\n";
			if ( $deletemanual ) {
				unless ($line =~ /Manual_state/ || $line =~ /Manual_time_to/ || $line =~ /Manual_time_from/ ) {
					print $confhandle $line;
				}
			} else {
				print $confhandle $line;
			}
		}
	}
}		

# compares active and working configuration
#   ... skippint comments and manual configuration
#   ... and removes uncecessary manual_* settings
sub compare_config
{
	my $firstconfigptr = shift;
	my $secondconfigptr = shift;

	my $firstindex = 0;
	my $secondindex = 0;
	my $coupled = 0;
	while (defined ( $$firstconfigptr[$firstindex]) && defined ($$secondconfigptr[$secondindex]) ) {																																																																																																																																																																														
		my $firstactive = $$firstconfigptr[$firstindex];
		$firstactive = canonize_active ( $firstactive );
#		if (length ( $firstactive ) < 1 ) {
# Manual_state_hack ----
		if ((length ( $firstactive ) < 1) || $firstactive =~ /Manual_state/ || $firstactive =~ /Manual_time_to/ || $firstactive =~ /Manual_time_from/ ) {
# ----------------------		
			$firstindex++;
			next;
		} else {
#												print "F: $firstindex --=> $firstactive\n";
			$coupled = 0;
		}
		my $secondactive = $$secondconfigptr[$secondindex];
		$secondactive = canonize_active ( $secondactive );
#		if (length ( $secondactive ) < 1 ) {
# Manual_state_hack ----
		if ((length ( $secondactive ) < 1) || $secondactive =~ /Manual_state/ || $secondactive =~ /Manual_time_to/ || $secondactive =~ /Manual_time_from/) {
# ----------------------		

			$secondindex++;
			next;
		} else {
#												print "S: $secondindex --=> $secondactive\n";
			$coupled = 0;
		}
		if ( $firstactive eq $secondactive ) {
#												print " ==>EQUEAL\n";
			$firstindex++;
			$secondindex++;
			$coupled = 1;
			next;
		} else {
			last;
		}
	}
	if ( $coupled ) {
		return 1;
	} else {
		return 0;
	}
}

# compares the endtime in the form YYYY:MM:DD:hh:mm with current time / checktime if specified
# returns 1 if the endtime is greater than the current time / checktime
sub compare_endtime
{
	my $endtime = shift;
	my $checktime = shift;

#																		print "   Comparing $endtime vs $checktime\n";
	unless (defined ( $endtime ) ){
		return 0;
	}
	unless ( $endtime =~ /\d\d\d\d:\d\d:\d\d:\d\d:\d\d/ ) {
		return 0;
	}
	my ($eyear, $emonth, $eday, $ehour, $emin) = split /:/, $endtime;
	my ($csec,$cmin,$chour,$cmday,$cmon,$cyear,$cwday,$cyday,$cisdst);
	if ( defined $checktime ) {
		($csec,$cmin,$chour,$cmday,$cmon,$cyear,$cwday,$cyday,$cisdst) = localtime ($checktime);
		$cyear += 1900;
		$cmon++;
	} else {
		($csec,$cmin,$chour,$cmday,$cmon,$cyear,$cwday,$cyday,$cisdst) = ($main::sec,$main::min,$main::hour,$main::mday,$main::mon,$main::year,$main::wday,$main::yday,$main::isdst);
	}

	
	if (($eyear == 0) && ($emonth == 0) && ($eday == 0) && ($ehour == 0) && ($emin == 0)) {
		return 1;
	}
	if ( $eyear < $cyear ) {
		return 0;
	}
	if ( $eyear > $cyear ) {
		return 1;
	}
	if ( $emonth < $cmon ) {
		return 0;
	}
	if ( $emonth > $cmon ) {
		return 1;
	}
	if ( $eday < $cmday ) {
		return 0;
	}
	if ( $eday > $cmday ) {
		return 1;
	}
	if ( $ehour < $chour ) {
		return 0;
	}
	if ( $ehour > $chour ) {
		return 1;
	}
	if ( $emin <= $cmin ) {
		return 0;
	}
	return 1;
}