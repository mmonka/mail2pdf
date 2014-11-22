#!/usr/bin/perl

use strict;
use warnings;
use Mail::Mbox::MessageParser;


# Arguments
my ($mboxfile) = @ARGV;

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
		} );



die $folder_reader unless ref $folder_reader;

warn "No cached information" if $Mail::Mbox::MessageParser::Cache::UPDATING_CACHE;

# Any newlines or such before the start of the first email
my $prologue = $folder_reader->prologue;
print $prologue;

# This is the main loop. It's executed once for each email
while(! $folder_reader->end_of_file() )
{
	my $email = $folder_reader->read_next_email();
	print $email;
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
