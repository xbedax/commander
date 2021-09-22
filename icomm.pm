#!/usr/bin/perl

# user specific connection parameters
# revised connection reconnect
# continue reading call back
# set_param


#package initer;
@EXPORT = qw(set_param send_command_XX send_command2 create_connection close_all);
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
use IO::Socket;
use IO::Socket::INET;
use IO::Select;
#use Device::Modbus::TCP::Client; 

#package icomm;
our $VERSION = "2.01.01";


my $EOL = "\015";
my $connected = 0;
my $RSconv;
my $Select_client = new IO::Select();
my $current_client;
my @sockets_ready;
my $sock;
my %clientstab;

my $connection_retries = 2;
my $commandretrycount = 5;
my $commandretrypause = 2;
my $readwritetimeout = 1;
my $connectionsetuptimeout = 2;
my $connectionretrypause = 2;

#$/ = "\015";

$SIG{PIPE} = sub { 
	warn "Lost connection to server: $!"; 
	$connected = 0; 
	####If we receieved SIGPIPE signal then call Disconnect this client function
																	printlog ( 4,  "Received SIGPIPE , removing a client..");
	unless(defined $current_client){
																	printlog (4, "No clients to remove!");
		}else{
		$Select_client->remove($current_client);
		$current_client->close;
	}
	#print Dumper $Self->Select->handles;
#	print "Total connected clients =>".(($Select_client->count)-1)."<\n";
};

# changes communication parameters
# 	commandretry - number of command retries
#	commandpause - pause between command retries (in sec)
#	commandtimeout - how many secs wait for command response
#	connectiontimeout - secs to wait for connection 
 
sub set_param
{
	my %args = @_;
#																		print "ICOMM: Initialization performed\n";
	if ( defined ( $args{commandretry} ) ) {
		$commandretrycount = $args{commandretry};
																			#print "ICOMM: Command retry changed: $commandretrycount\n";	
	}
	if ( defined ( $args{commandpause} ) ) {
		$commandretrypause = $args{commandpause};
	}
	if ( defined ( $args{commandtimeout } ) ) {
		$readwritetimeout = $args{commandtimeout};
	}
	if ( defined ( $args{connectiontimeout } ) ) {
		$connectionsetuptimeout = $args{connectiontimeout};
	}
	if ( defined ( $args{connectionpause} ) ) {
		$connectionretrypause = $args{connectionpause};
	}
	if ( defined ( $args{connectionretry} ) ) {
		$connection_retries = $args{connectionretry};
	}
	
}

sub close_all
{
	my @socks = $Select_client->handles;
	
	foreach my $socket (@socks) {
																		printlog ( 5, "Closing socket $socket " );
		$socket->close;
		
	}
	undef %clientstab;
	return 1;
}
# obsoleted - hopefully
sub send_command_XX 
{
	my $command = shift;
	my $remote = shift;
	my $port = shift;
# 	my $maxdata = shift;
	my $response = "";
	my $readerror;	
	my $writesuccess;
	my $sock;
	my $responsebytes = 0;
	my $responseread = 0;


#	$current_client = $sock;			
	unless ( defined ( $clientstab{$remote}{$port} ) ) {
		create_connection ($remote, $port);
	}

    for my $retrycount (0..$commandretrycount) {
		$readerror = $writesuccess = 0;
        if (defined  ( $clientstab{$remote}{$port} ) )  {
			$current_client = $sock = $clientstab{$remote}{$port}; 	
																		printlog (3, "About to send command XX $command");
			my @Write_socks = $Select_client->can_write($readwritetimeout);
			foreach my $wsock (@Write_socks) {
				if ($wsock == $sock ) {
#					$writesuccess = print $sock "$command" , $EOL;
					$writesuccess = print $sock "$command";

				}
			}
			if ( $writesuccess ) {
				flush $sock;
																		printlog (3, "About to read response");
				my $socketerror = 1;
				my $socketwait = 0;
				while ( ( index ( $response, $EOL ) < 0 ) && (($responseread < $responsebytes) || ($responsebytes == 0)) && ($socketwait < 3)) {
						$socketwait++;
#					for (1..2) {
						my @Read_socks = $Select_client->can_read($readwritetimeout);
#																			print "Selectable sockets:\n";
#																			print Dumper $Select_client;
#																			print "Readable sockets selected:\n";
#																			print Dumper @Read_socks;
						
						
																			printlog (5, scalar (@Read_socks) . " sockets to read");
						
						foreach my $ssock (@Read_socks) {
							if ($ssock == $sock ) {
								$socketwait = 0;	
								$socketerror = 0;
		#						if ( defined($response = <$RSconv>) ) {
		#							chomp $response;
		#							return $response;
								
								my $bytesread = sysread ( $sock, $response, 64, length($response) );
																		printlog (5, "Bytes read ($bytesread) ");
								if (defined $bytesread) {
									if ($bytesread) {
#										return $response;
										$readerror = 0;
									} else {
																		printlog (3, "ERR: Closed socket");
										$readerror = 1;
									}
								} else {
																		printlog (3, "ERR: Error Socket");
									$readerror = 1;
								}
							}
						}
#						if ( $readerror ) {
#							sleep 1;
#						}else {
#							last;
#						}
#					}
					if ($readerror + $socketerror) {
						last;
					}
				}
				if (! ($readerror + $socketerror )) {
																		printlog (3, "    ---> $response");
					return $response;
				}
			}
		}
		if ( $retrycount ) {
			sleep $commandretrypause;
																		printlog (3, "ERR: Reconnecting to $remote:$port ($retrycount)");
			if ( defined ( $sock ) ) {
				$Select_client->remove($sock);
				$sock->close;
				undef ($clientstab{$remote}{$port});
			}
		}
        create_connection ($remote, $port);
    }
    return undef;
}
# Sends command to target device and receives response
# ... including timeouts handling, retries, error checking and other communication stuff
# returns text information descripting the result of communication:
#		COM_NOCONNECTION - no coonection to gateway
#		COM_CONNECTED - connection to gateway achieved
#		COM_SENT - command sent do gateway
#		COM_RESPONSE - at least part of response received
#		COM_READCLOSED - connection closed prematurely
#		COM_READERROR -	read socket error
#		COM_SUCCESS - response received succesfully
#		the response received is stored to responsebuff specified in 3rd parameters
#		the function expects a call back pointer to function thet provides info whether the response received so far is complete or additional data are expected

sub send_command2 
{
	my $command = shift;
	my $remote = shift;
	my $port = shift;
	my $responsebufptr = shift;
	my $continue_reading = shift;
# 	my $maxdata = shift;

	my $readerror;	
	my $writesuccess;
	my $sock;
	my $responsebytes = 0;
	my $responseread = 0;
	my $state = "COM_NOCONNECTION";


#	$current_client = $sock;			
	unless ( defined ( $clientstab{$remote}{$port} ) ) {
		create_connection ($remote, $port);
	}

	my $retrycount;
    for $retrycount (0..$commandretrycount) {
		$readerror = $writesuccess = 0;
        if (defined  ( $clientstab{$remote}{$port} ) )  {
			$state = "COM_CONNECTED";
			$current_client = $sock = $clientstab{$remote}{$port}; 	
																		printlog (3, "About to send command $command");
			my @Write_socks = $Select_client->can_write($readwritetimeout);
			foreach my $wsock (@Write_socks) {
				if ($wsock == $sock ) {
#					$writesuccess = print $sock "$command" , $EOL;
					$writesuccess = print $sock "$command";

				}
			}
			if ( $writesuccess ) {
#				flush $sock;
																		printlog (3, "About to read response");
				$state = "COM_SENT";
				my $socketerror = 1;
				my $socketwait = 0;
				my $bytesreadtotal = 0;
				do {
					$socketwait++;
					my @Read_socks = $Select_client->can_read($readwritetimeout);
#																			print "Selectable sockets:\n";
#																			print Dumper $Select_client;
#																			print "Readable sockets selected:\n";
#																			print Dumper @Read_socks;
						
						
																			printlog (5, scalar (@Read_socks) . " sockets to read");
						
					foreach my $ssock (@Read_socks) {
						if ($ssock == $sock ) {
							$socketwait = 0;	
							$socketerror = 0;
							my $bytesread = sysread ( $sock, $$responsebufptr, 64, length($$responsebufptr) );
																		printlog (5, "Bytes read ($bytesread) ");
							if (defined $bytesread) {
								if ($bytesread) {
#									return $response;
#									$$responsebufptr .= $response;
									$bytesreadtotal += $bytesread;
									$readerror = 0;
									$state = "COM_RESPONSE";
								} else {
																		printlog (3, "ERR: Closed socket");
									$readerror = 1;
									$state = "COM_READCLOSED";
								}
							} else {
																		printlog (3, "ERR: Error Socket");
								$readerror = 1;
								$state = "COM_READERROR";
							}
						}
					}
					if ($readerror + $socketerror) {
						last;
					}
				}while (&$continue_reading($responsebufptr) && ($socketwait < 3)); 
				if (! ($readerror + $socketerror )) {
					$state = "COM_SUCCESS";
																		printlog (3, "    ---> $state");
					return $state;
				}
			}
		}
		if ( $retrycount ) {
			sleep $commandretrypause;
																		printlog (3, "ERR: Reconnecting to $remote:$port ($retrycount)");
			if ( defined ( $sock ) ) {
				$Select_client->remove($sock);
				$sock->close;
				undef ($clientstab{$remote}{$port});
			}
		}
        create_connection ($remote, $port);
    }
    return $state;
}

# creates TCP connection and stores it to clienttab

sub create_connection
{
	my $remote_address = shift;
	my $remote_port = shift;
	my $conn;
	
	for (1..$connection_retries) {
																		printlog ( 5, "Creating connection ($_)");
		if ($conn = IO::Socket::INET->new(
									PeerAddr=> $remote_address,
									PeerPort=> $remote_port,
									Proto=> "tcp",
									Blocking => 1,
									Timeout => $connectionsetuptimeout) ) {
			$Select_client->add($conn);
			$conn->autoflush(1);
			$clientstab{$remote_address}{$remote_port} = $conn;
			last;
		}
																		printlog (3, "ERR: Retrying connection to $remote_address:$remote_port");
		sleep 2;
	}
	return $conn;
}

1;


# TO DO
# comunikacni parametry per GW