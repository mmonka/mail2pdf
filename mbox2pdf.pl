#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;
use Mail::Mbox::MessageParser;
use Email::Simple;
use Getopt::Long;
    
# Global Variables
my $mboxfile;
my $verbose;
my $debug;

GetOptions(	"mboxfile=s" => \$mboxfile, # string
    		"verbose" => \$verbose,
    		"debug" => \$debug
	  ) # flag
or die("Error in command line arguments\n");

# Check file
if (!check_mbox_file($mboxfile)) {

	error("FATAL", "File '$mboxfile' does not fit");
	exit;
}

my $filehandle = new FileHandle($mboxfile);


# Set up cache
Mail::Mbox::MessageParser::SETUP_CACHE(	{ 'file_name' => '/tmp/cache' } );

# Vars
my $folder_reader = new Mail::Mbox::MessageParser( {
		'file_name' => $mboxfile,
		'file_handle' => $filehandle,
		'enable_cache' => 1,
		'enable_grep' => 1,
		'debug' => $debug,
		} );



die $folder_reader unless ref $folder_reader;

warn "No cached information" if $Mail::Mbox::MessageParser::Cache::UPDATING_CACHE;

# Any newlines or such before the start of the first email
my $prologue = $folder_reader->prologue;

# This is the main loop. It's executed once for each email
while(! $folder_reader->end_of_file() )
{
	my $content = $folder_reader->read_next_email();
	my $email = Email::Simple->new($content);
	
	# Date, Subject
	my $date = $email->header("Date");
	my $subject = $email->header("Subject");

	my $body = $email->body;

	logging("Info", "Subject '$subject'\n Date '$date'");
	
}
# --------------------------------------------------------
# Logging 
# --------------------------------------------------------
sub logging {

	my ($LEVEL, $msg) = @_;

	printf("%s\n", $msg);
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
