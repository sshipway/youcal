#!/usr/bin/perl
#vim:ts=4
#
# This should grab a list of tickets from YouTrack, and serve them up as
# an iCal calendar for synchronisation, based on field names and filters
# provided in the config file.
#
# Steve Shipway, SMX, Sept 2019
#
## youcal.conf Needs these options set (dont set tzid if in GMT)
# url=https://youtrack.company.com
# token=perm:xxxxxx
# filter=project: CC state: -Cancelled has: {Start Time} has: {End Time} created: {Last month} .. Today
# field-start=Start Time
# field-end=End Time
# field-state=State
# field-state-cancelled=Cancelled
# field-approval=Approval Status
# field-approval-approved=Approved
# field-approval-submitted=Submitted
# field-owner=Assignee
# default-domain=smxemail.com
# event-categories=Change
# tzid=Pacific/Auckland
#
# Version: 2.1

use strict;
use Date::Format qw(time2str);
use Getopt::Long qw(:config no_ignore_case);
use CGI;
use LWP;
use JSON;
use Encode;
use Data::Dumper;
use IO::Socket::SSL;
use POSIX;

my(%opts) = ();
my($CONFIG) = "/etc/youcal/youcal.conf";
my($DEBUG) = 0;

my(%events) = ();

my $q = CGI->new;
my($ua) = LWP::UserAgent->new(
    ssl_opts => {
        verify_hostname => 0 , # because we're coming in the back door
        SSL_verify_mode => SSL_VERIFY_NONE, # because reasons
    },
	cookie_jar=>{}  # must preserve cookies
);

#########################################################################
sub do_help() {
	print "Usage: $0 [-d][-C|-A|-I] [-c configfile] [-o opt=val ...] [cfgfile]\n";
	print "-d : Debug mode\n";
	print "-C : CGI mode - output ICAL with headers\n";
	print "-A : AppSuite update mode\n";
	print "-I : Output ICAL calendar\n";
	print "-o opt=val : Override configuration file to set opt to val\n";
	print "Environment YOUCAL_URL and YOUCAL_TOKEN can override the config file settings\nfor url and token.\n";
	exit 0;
}
# Read in the configuration file
sub readconf($) {
	my $cfg = $_[0];
	open CONF,"<$cfg" or do {
		print STDERR "Unable to read '$cfg'\n";
		exit 1;
	};

	while ( <CONF> ) {
		chomp;
		if( /^\s*([^\s=]+)\s*=\s*(\S.*)/ ) {
			$opts{$1} = $2;
		}
	}

	close CONF;
}

# Make a REST call to youtrack API
sub youtrack($$$$) {
	my($method,$path,$data,$options) = @_;
	my($response, $request, $body, $uri);
	my($rv);

	$uri = $opts{url}."/api/".$path;
	$uri =~ s/\/+api\/+/\/api\//;
	if( $options ) {
		$uri .= "?";
		foreach my $k ( keys %$options ) {
			my($var) = "";
			if( ref $options->{$k} ) {
				$var = "$k=".(join ",",@{$options->{$k}});
			} else {
				$var = "$k=".$options->{$k};
			}
			$var =~ s/ /+/g;
			$uri .= "$var&";
		}
	}
	print "$uri\n" if($DEBUG>1);
	$body = encode_utf8(encode_json($data));
	$request = HTTP::Request->new( $method, $uri );
	$request->accept_decodable();
	$request->content( $body );
    $request->header('Authorization' => "Bearer ".$opts{token});
    if($DEBUG>1) { print "Bearer ".$opts{token}."\n"; }
	$request->header('Content-Type' => 'application/json; charset=UTF-8');
	$request->header('Accept' => 'application/json');
	$request->header('Cache-Control' => 'no-cache');
	$response = $ua->request($request);
	
	if ( $response->code()>299 or $response->code()<200 ) {
		$rv =  {"error"=>$response->status_line()}
	} else {
		eval {
			$rv = decode_json( $response->decoded_content() );
		};
		if($@) {
			$rv =  {"error"=>$@}
		}
	}
	if($DEBUG and $rv and (ref $rv eq "HASH") and defined $rv->{error}) {
		print "ERROR: ".$rv->{error}."\n";
	}
	return $rv;
}

sub icaltime($) {
	if( $_[0] ) {
		return time2str( "%Y%m%dT%H%M%S", $_[0]/1000 );
	}
	return "";
}
############################################################################
# fetch all events from youtrack API
sub fetch_events() {
	my $rv;

	if($DEBUG) { 
		$rv = youtrack("GET","/admin/users/me",{},{"fields"=>['id','login','name','email']}); 
		print Dumper($rv);
	}

	# Search all issues according to filter query, retrieving specified fields
	$rv = youtrack("GET","/issues",{},{
		"fields"=>['id','idReadable','created','project(name,shortName,id)','summary','description','customFields(projectCustomField(field(name)),value(fullName,id,login,name,email))'],
		"query"=>$opts{filter}
	}); 

	# We might receive a single item, or an array
	if( ref $rv eq "HASH" ) {
		addevent($rv);
	} elsif( ref $rv eq "ARRAY" ) {
		foreach my $e ( @$rv ) {
			addevent($e);
		}
	} else {
		print "Unknown response: $rv\n";
	}
}
# Add this event to the list, if valid
sub addevent($) {
	my($eventref) = $_[0];
	my(%fields) = ();

	if( $eventref->{error} ) {
		print "ERROR: ".$eventref->{error}."\n";
		return;
	}

	# Extract data from all custom fields into our new hash
	foreach my $f ( @{$eventref->{customFields}} ) {
		my $n = $f->{projectCustomField}{field}{name};
		my $v = $f->{value};
		if( ref $v eq "HASH" and defined $v->{name} ) {
			$fields{$n}=$v->{name};
			$fields{$n."_email"}=$v->{email} if(defined $v->{email});
			$fields{$n."_login"}=$v->{login} if(defined $v->{login});
		} elsif( ref $v eq "ARRAY" ) {
			my $val = '';
			foreach my $vv ( @$v ) {
				$val .= ', ' if($val);
				if( ref $vv eq "HASH" ) {
					$val .= $vv->{name} if(defined $vv->{name});
				} else {
					$val .= $vv;
				}
			}
			$fields{$n}=$val;
		} else {
			$fields{$n}=$v;
		}
	}
	# Now extract standard fields into the hash
	foreach my $f ( qw/description summary id idReadable project created/ ) {
		my $v = $eventref->{$f};
		next if(!defined $v);
		if( ref $v eq "HASH" and defined $v->{name} ) {
			$fields{$f}=$v->{name};
		} else {
			$fields{$f}=$v;
		}
	}

	# Reject events without key data
	if(! $fields{idReadable} 
		or !$fields{summary}
		or !$fields{$opts{'field-start'}}
		or !$fields{$opts{'field-end'}}
	) {
		if($DEBUG) {
			print "Rejecting this event as it does not have required fields.\n";
			print "idReadable: ".$fields{idReadable}."\n";
			print "summary: ".$fields{summary}."\n";
			print "start: ".$fields{$opts{'field-start'}}."\n";
			print "end: ".$fields{$opts{'field-end'}}."\n";
		}
		return;
	}

	if( $opts{active} ) {
		# Skip events that are not completed, approved or in progress
		print "Checking event is active\n" if($DEBUG);
		if(!$fields{$opts{'field-approval'}}
			or $fields{$opts{'field-approval'}} ne $opts{'field-approval-approved'} ) {
			print "Skipping unapproved event\n" if($DEBUG);
			return; 
		}
		if( $fields{$opts{'field-state'}} eq $opts{'field-state-cancelled'} ) {
			print "Skipping cancelled event\n" if($DEBUG);
			return; 
		}
		print $fields{idReadable}." State: ".$fields{$opts{'field-state'}}." Approved: ".$fields{$opts{'field-approval'}}."\n"
			if($DEBUG);
	}

	# Add the event to the list
	$events{$eventref->{id}} = \%fields;

	if($DEBUG) { 
		print "Adding event: ".$eventref->{idReadable}."\n"; 
		if($DEBUG>1) {
			print Dumper($eventref)."\n";
			print "Parsed data:\n";
			print Dumper(\%fields)."\n";
		}
	}
}

############################################################################
# Output events as an iCal calendar
sub print_ical() {

	print "BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//smxemail.com//YouCal 1.0//EN\nCALSCALE:GREGORIAN\n";

	# Loop through all items in the %events hash
	foreach my $k ( keys %events ) {
		# The description needs to be change to use \n and initial 2space
		# on continuation lines
		my($desc) = $events{$k}{description};
		my($summary) = $opts{'summary-format'};
		my($status) = "Unknown";

		if( $events{$k}{$opts{'field-state'}} eq $opts{'field-state-submitted'} ) {
			$status = $events{$k}{$opts{'field-approval'}};
			print $events{$k}{idReadble}." Approval ".$events{$k}{$opts{'field-approval'}}."\n"
				if($DEBUG);
		} else {
			print $events{$k}{idReadble}." State ".$events{$k}{$opts{'field-state'}}." is not ".$opts{'field-state-submitted'}."\n"
				if($DEBUG);
			$status = $events{$k}{$opts{'field-state'}};
		}
		$status =~ s/ /-/g;
		$status = "Unknown" if(!$status);
		
		$desc =~ s/\n/\\n\n  /g;
		$summary =~ s/\%id/$events{$k}{idReadable}/eg;
		$summary =~ s/\%(summary|description)/$events{$k}{summary}/eg;
		$summary =~ s/\%(owner|organi[zs]er|user)/$events{$k}{$opts{'field-owner'}}/eg;
		$summary =~ s/\%stat(e|us)/$status/eg;
		$summary =~ s/\%approv(al|ed)/$events{$k}{$opts{'field-approval'}}/eg;


		# Start the event object
		print "BEGIN:VEVENT\n";
		print "SUMMARY:$summary\n";
		print "UID:".$events{$k}{id}.'@'.$opts{url}."\n";
		#print "SEQUENCE:0\n";
		# Set status according to approval and state
		if( $events{$k}{$opts{'field-state'}} ne $opts{'field-state-cancelled'} ) {
			if( $events{$k}{$opts{'field-approval'}} ne $opts{'field-approval-approved'} ) {
				print "STATUS:TENTATIVE\n";
			} else {
				print "STATUS:CONFIRMED\n";
			}
		} else {
			print "STATUS:CANCELLED\n";
		}
		print "TRANSP:TRANSPARENT\n";
		# Set times.  This can depend on timezone
		print "DTSTART".($opts{'tzid'}?";TZID=".$opts{'tzid'}:"").":".icaltime($events{$k}{$opts{'field-start'}}).($opts{tzid}?"":"Z")."\n";
		print "DTEND".($opts{'tzid'}?";TZID=".$opts{'tzid'}:"").":".icaltime($events{$k}{$opts{'field-end'}}).($opts{tzid}?"":"Z")."\n";
		#print "DTSTAMP".($opts{'tzid'}?";TZID=".$opts{'tzid'}:"").":".icaltime($events{$k}{$opts{'created'}}).($opts{tzid}?"":"Z")."\n";
		print "DESCRIPTION:$desc\n";
		print "URL:".$opts{url}."/issue/".$events{$k}{idReadable}."\n";
		# The owner of the change is made the meeting attendee
		# Note that not all have email attributes (why?) and so we use
		# the login attribute with default domain instead
		if(defined $events{$k}{$opts{'field-owner'}}) {
			print "ORGANIZER;CN="
				.$events{$k}{$opts{'field-owner'}}
				.":mailto:"
				.($events{$k}{$opts{'field-owner'}."_email"}?
					$events{$k}{$opts{'field-owner'}."_email"}:
					$events{$k}{$opts{'field-owner'}."_login"}."@".$opts{'default-domain'}
				)."\n";
			print "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN="
				.$events{$k}{$opts{'field-owner'}}
				.":mailto:"
				.($events{$k}{$opts{'field-owner'}."_email"}?
					$events{$k}{$opts{'field-owner'}."_email"}:
					$events{$k}{$opts{'field-owner'}."_login"}."@".$opts{'default-domain'}
				)."\n";
			print "CONTACT:".$events{$k}{$opts{'field-owner'}}."\n";
		}
		print "CATEGORIES:$status,".$opts{'event-categories'}."\n";
		print "LOCATION:".$events{$k}{'Platform'}."\n"
			if( $events{$k}{'Platform'} );
		print "END:VEVENT\n";
	}


	print "END:VCALENDAR\n";

}

############################################################################
# Print a list of events in human-readable form
sub print_events() {
	foreach my $k ( keys %events ) {
		my($status) = "Unknown";

		if( $events{$k}{$opts{'field-state'}} eq $opts{'field-state-submitted'} ) {
			$status = $events{$k}{$opts{'field-approval'}};
			print $events{$k}{idReadble}." Approval ".$events{$k}{$opts{'field-approval'}}."\n"
				if($DEBUG);
		} else {
			print $events{$k}{idReadble}." State ".$events{$k}{$opts{'field-state'}}." is not ".$opts{'field-state-submitted'}."\n"
				if($DEBUG);
			$status = $events{$k}{$opts{'field-state'}};
		}
		$status =~ s/ /-/g;
		$status = "Unknown" if(!$status);

		print "Change: ".$events{$k}{idReadable}.' '.$events{$k}{summary}
			." ($status)\n"
			."Owner: ".$events{$k}{$opts{'field-owner'}}."\n";
		print "Start: ".localtime($events{$k}{$opts{'field-start'}}/1000)."\n";
		print "End  : ".localtime($events{$k}{$opts{'field-end'}}/1000)."\n";
		print "\n";
	}
}

############################################################################
# Update shared calendar in Appsuite
sub update_appsuite() {
	# Havent worked out how to do this yet
}

#########################################################################
# Main

# Process options
$opts{config} = $CONFIG;
$opts{'summary-format'}='%id %summary (%state)';
GetOptions( \%opts, "config=s", "debug+", "help|?", 
	"cgimode|C", "appsuite|A", "ical|I", "active|a",
    "options|o=s@" );
do_help() if($opts{help});
$DEBUG = $opts{debug} if($opts{debug});

if( $ARGV[0] and -f $ARGV[0] ) { $opts{config} = $ARGV[0]; }
# Environment variable settings lowest priority
$opts{url} = $ENV{YOUCAL_URL} if( $ENV{YOUCAL_URL} );
$opts{token} = $ENV{YOUCAL_TOKEN} if( $ENV{YOUCAL_TOKEN} );
# Configuration file settings
readconf($opts{config});
# Commandline options take priotiry
if( $opts{options} ) {
	foreach my $o ( @{$opts{options}} ) {
		if( $o =~ /^\s*([^\s=]+)\s*=\s*(\S.*)/ ) {
			$opts{$1}=$2;
		}
	}
}

# Detect when we're running as a CGI script
if( $q->request_method() ) { 
	$opts{cgimode} = 1; 
	if($q->param('active')) { $opts{active} = 1; }
}

# Fetch events from youtrack
fetch_events();

# CGI mode needs a header
if( $opts{cgimode} ) {
	print $q->header('text/calendar');
}

# Output in the chosen form
if($opts{cgimode} or $opts{ical}) {
	print_ical();
} elsif( $opts{appsuite} ) {
	update_appsuite();
} else {
	print_events();
}

# Exit nicely
exit 0;
