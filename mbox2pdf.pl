#!/usr/bin/perl

use lib '/Users/markus/perl5/lib/perl5/';

use strict;
use warnings;
use Data::Dumper;
use Mail::Mbox::MessageParser;
use MIME::Parser;
use MIME::Words qw(:all);
use MIME::Body;
use Email::Simple;
use Email::MIME;
use Getopt::Long;
   
# --------------------------------------------------
# Global Variables
# --------------------------------------------------
my $mboxfile;
my $verbose;
my $debug;

# --------------------------------------------------
# Getopt definition
# --------------------------------------------------
GetOptions(	"mboxfile=s" => \$mboxfile, # string
    		"verbose" => \$verbose,
    		"debug" => \$debug
	  ) # flag
or die("Error in command line arguments\n");

 
MIME::Tools->debugging(1) if($debug);
MIME::Tools->quiet(1) if($verbose);

# --------------------------------------------------
# Check file
# --------------------------------------------------
if (!check_mbox_file($mboxfile)) {

	error("FATAL", "File '$mboxfile' does not fit");
	exit;
}

# --------------------------------------------------
# new FileObjekt
# --------------------------------------------------
my $filehandle = new FileHandle($mboxfile);


# Set up cache
# Mail::Mbox::MessageParser::SETUP_CACHE(	{ 'file_name' => '/tmp/cache' } );

# --------------------------------------------------
# new MboxParser Objekt
# --------------------------------------------------
my $mbox = new Mail::Mbox::MessageParser( {
		'file_name' => $mboxfile,
		'file_handle' => $filehandle,
		'enable_cache' => 0,
		'enable_grep' => 0,
		'debug' => $debug,
		} );



die $mbox unless ref $mbox;

# --------------------------------------------------
# Any newlines or such before the start of the first email
# --------------------------------------------------
my $prologue 	= $mbox->prologue;

# --------------------------------------------------
# value for logging
# --------------------------------------------------
my $email_count = 1;

# --------------------------------------------------
# This is the main loop. It's executed once for each email
# --------------------------------------------------
while(! $mbox->end_of_file() )
{
	my $content = $mbox->read_next_email();
	
	my $parser = new MIME::Parser;

	$parser->ignore_errors(0);
	$parser->output_to_core(5);

	my $entity = $parser->parse_data($content);
	my $error = ($@ || $parser->last_error);
	
	# get email headers
	my $header = $entity->head;
	my $subject = $header->get('Subject');
	my $to = $header->get('To');
	my $from = $header->get('From');
	my $date = $header->get('Date');
	my $contenttype = $header->get("Content-Type");

	# if from facebook, skip
	next if($from =~ /facebook/);

	# delete newlines
	chomp($subject);
	chomp($to);
	chomp($from);
	chomp($date);
	chomp($contenttype);

	# decode subject 
	if($subject =~ /.*(utf-8|utf8).*/) {

		logging("DEBUG", "Subject encoding is utf8");
		my $decoded = decode_mimewords($subject);

		# Fix encoding
		$subject = $decoded;

	}
	
	logging("INFO", "Email Nr: $email_count");
	logging("INFO", "Date '$date'");
	logging("INFO", "From '$from'");
	logging("INFO", "Subject '$subject'");
	logging("INFO", "Email Content-Type '$contenttype'\n");
	
	# returns a hash ref with mime content
	my $mail = handle_mime_body($entity);

	$email_count++;	
}

# --------------------------------------------------------
# Handle Body  
# --------------------------------------------------------
sub handle_mime_body {

	my $entity 	= shift;

	my $plain_body 	= "";
	my $html_body 	= "";
	my $content_type;

	# --------------------------------------------
	# get email body
	# --------------------------------------------
	if ($entity->parts > 0){

    		for (my $i=0; $i<$entity->parts; $i++){

			# Mime Parts 
			my $subentity = $entity->parts($i);

			# For "singlepart" types (text/*, image/*, etc.), the unencoded body data is referenced 
			# via a MIME::Body object, accessed via the bodyhandle() method
			if($subentity->head->get('content-type') =~ "text") {
				
				my $body	= $subentity->bodyhandle;
				my @lines 	= $body->as_lines;
				my $string	= "";				

				foreach (@lines) {

					chomp($_);
					$string = sprintf("%s %s", $string, $_);

				}
				
				logging("VERBOSE", "Part $i - Type Text '$string'");
			}
			elsif($subentity->head->get('content-type') =~ "image") {

				logging("VERBOSE", "Part $i - Type Image");
			}
			elsif($subentity->head->get('content-type') =~ "video") {

				logging("VERBOSE", "Part $i - Type Video");
			}
		}
	}
	else {

		logging("INFO", "No Body-Part found");
	}

	return 0;
}


# --------------------------------------------------------
# Logging 
# --------------------------------------------------------
sub logging {

	my ($LEVEL, $msg) = @_;

	if($debug && $LEVEL eq "DEBUG") {

		printf("%s: %s\n", $LEVEL, $msg);
	} 
	elsif ($verbose && ( $LEVEL eq "VERBOSE" || $LEVEL eq "INFO" ) )  {

		printf("%s: %s\n", $LEVEL, $msg);
	} 
	else {

		# no logging
	}

	return 0;
}

# --------------------------------------------------------
# Validate File
# --------------------------------------------------------
sub check_mbox_file {

	my $file = shift;

	return 1 if ( -f $file ); 

	return 0;
}

# --------------------------------------------------------
# Handle Error 
# --------------------------------------------------------
sub error {

	my ($level, $msg) = @_;

	printf("%s\n", $msg);

	return 0;
}
