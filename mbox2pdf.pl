#!/usr/bin/perl

use lib '/Users/markus/perl5/lib/perl5/';

use strict;
use warnings;
use Data::Dumper;
use Mail::Mbox::MessageParser;
use MIME::Parser;
use MIME::Words qw(:all);
use MIME::Body;
use PDF::Create;
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
     print MIME::Tools->version, "\n" if($verbose);

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
# PDF Vars
# --------------------------------------------------
my $pdf;

# --------------------------------------------
# create a pdf file / pdf object $pdf 
# --------------------------------------------
pdf_file("create");

# --------------------------------------------------
# This is the main loop. It's executed once for each email
# --------------------------------------------------
while(! $mbox->end_of_file() )
{
	my $content = $mbox->read_next_email();
	
	my $parser = new MIME::Parser;

	$parser->ignore_errors(0);
	$parser->output_to_core(0);

	my $entity = $parser->parse_data($content);
	my $header = $entity->head;
	my $error = ($@ || $parser->last_error);
	
	
	# returns text as a list
	# returns all images as an array 
	my ($text_ref,$images_ref) = handle_mime_body($email_count,$entity);

	my @text 	= @$text_ref;
	my @images 	= @$images_ref;

	pdf_add_email($header, @text, @images);

	$email_count++;	
	last;
}

pdf_file("close");
exit;

# --------------------------------------------------------
# Handle Body  
# --------------------------------------------------------
sub handle_mime_body {
	
	my $email_count = shift;
	my $entity 	= shift;

	my $plain_body 	= "";
	my $html_body 	= "";
	my $content_type;

	# My Email Text
	my @text;				
    	my @images;


	# --------------------------------------------
	# get email body
	# --------------------------------------------
	if ($entity->parts > 0){

	
		for (my $i=0; $i<$entity->parts; $i++){


			# Mime Parts 
			my $subentity = $entity->parts($i);
			
			# --------------------------------------
			# Content Type of Part
			# --------------------------------------
			my $ct =  $subentity->mime_type;
			logging("VERBOSE", "Part $i - Content type '$ct'");
	
			# For "singlepart" types (text/*, image/*, etc.), the unencoded body data is referenced 
			# via a MIME::Body object, accessed via the bodyhandle() method
			if($ct =~ "text") {
			
				my @lines	= $subentity->bodyhandle->as_lines;
			
				foreach(@lines) {
		
					$_ =~ s/\r\n//;	
					$_ =~ s/\n//;	
					
					push(@text, $_) if ( defined $_ && length($_) > 0);	
				}
			}
			elsif($ct =~ "image") {
				
				# FIXME
				my $filename = sprintf("%s_%s", $email_count, $subentity->head->recommended_filename);
				# push(@images, $subentity->bodyhandle->as_string);
	
				
			}
			elsif($ct =~ "video") {

				logging("VERBOSE", "Part $i - Type '$ct'");
			}
		}

	}
	else {

		logging("INFO", "No Body-Part found");
		return 0;
	}

	# Return array be reference
	return (\@text, \@images);
}

# --------------------------------------------------------
# Handle PDF
# --------------------------------------------------------
sub pdf_file {
	
	my $task = shift;
	my $filename = "/Users/markus/Desktop/feline_tagebuch.pdf";


	if($task eq "create") {
  		# initialize PDF
  		$pdf = PDF::Create->new('filename'     => $filename,
                                        'Author'       => 'Markus Monka',
                                        'Title'        => 'Feline Tagebuch',
                                        'CreationDate' => [ localtime ], );

		return $pdf;
	}
	elsif($task eq "close") {

		$pdf->close;

	}
	elsif($task eq "delete") {

		unlink $filename;

	}
	else {
		logging("ERROR", "Wrong task");
	}

}

# --------------------------------------------------------
# Add Email to an existing PDF File
# Each Email should be one page 
# --------------------------------------------------------
sub pdf_add_email {

	my $header 	= shift;
	my @text	= shift;
	my @images 	= shift;

	# get email headers
	my $subject = $header->get('Subject');
	my $to = $header->get('To');
	my $from = $header->get('From');
	my $date = $header->get('Date');
	my $contenttype = $header->get("Content-Type");

	# if from facebook, skip
	return 0 if($from =~ /facebook/);

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

	my $a4 = $pdf->new_page('MediaBox' => $pdf->get_page_size('A4'));

	# Add a page which inherits its attributes from $a4
  	my $page = $a4->new_page;
 
	# Prepare a font
  	my $f1 = $pdf->font('BaseFont' => 'Helvetica');
	
	# Mail Header Information 
  	$page->stringc($f1, 12, 150, 696, "von $from");
  	$page->stringc($f1, 12, 150, 722, "Datum $date");
  	$page->stringc($f1, 12, 150, 753, "Subject '$subject'");

	my $tmp = 1;
	my $content = "";
	foreach(@text) {

		if($tmp == 1) {
			logging("VERBOSE", "Text: $_");	
			$content = $content . $_ . "\r\n";
		}
		else {
			print $_;	
			my $jpg = $pdf->image($_);
  			$page->image( 'image' => $jpg, 'xscale' => 0.2, 'yscale' => 0.2, 'xpos' => 350, 'ypos' => 400 );

		}
		$tmp++;	
	}

  	$page->stringc($f1, 20, 150, 650, "Text: " . $content);
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
