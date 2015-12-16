#!/usr/bin/perl

use lib '/Users/markus/perl5/lib/perl5/';

use strict;
use warnings;
use Data::Dumper;

use Mail::IMAPClient;
use Mail::Mbox::MessageParser;

use Date::Parse;

use MIME::Parser;
use MIME::Words qw(:all);
use MIME::Body;
use MIME::Base64;

use PDF::Create;
use Getopt::Long;

use URI::Escape;
use Encode;
use utf8;

# Image Manipulatin
use Image::Magick;
   
# --------------------------------------------------
# Global Variables
# --------------------------------------------------
my $mboxfile;
my $verbose;
my $debug;
my $type;
my $help;
my $testlimit = 0;
my $start = 0;
my $end = 0;
# Path to PDF File
my $path = "/Users/markus/Desktop/";

our @text;
our @images;

# Move to credential-file
my $oauth_token = "";
my $username = ""; # Gmail Emailadress

# --------------------------------------------------
# Getopt definition
# --------------------------------------------------
GetOptions(	"mboxfile=s" => \$mboxfile, # string
    		"verbose" => \$verbose,
    		"debug" => \$debug,
            	"help" => \$help,
            	"type=s" => \$type,
            	"testlimit=s" => \$testlimit,
	  ) # flag
or die("Error in command line arguments\n");

if($help) {

	print "./mbox2pdf --options\n\n";
	print "--mboxfile=FILE              choose mbox file\n";
	print "--verbose                    enable verbose logging\n";
	print "--debug                      enable debugging\n";
    	print "--type mbox|imap             choose whether you want to use a local mbox file or a remote imap account\n";
	print "--testlimit=Start(,End)      choose at which position you want to start to generate the pdf file\n";
	exit;
}

# Testlimit is set
if($testlimit =~ /([\d]+),([\d]+)/) {

	$start = $1;
	$end   = $2;
	$testlimit = $2;

	if($start > $end) {
	
		$end = $start + $end;
		logging("INFO", "End looks like an Offset. Recalculate end ($end)");
	}	
	
	logging("VERBOSE", "Testlimit between '$start' '$end'");
}

 
MIME::Tools->debugging(1) if($debug);
MIME::Tools->quiet(0) if($verbose);


if($type eq "mbox") {
    
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
			'enable_grep' => 1,
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

	# --------------------------------------------
	# create a pdf file / pdf object $pdf 
	# --------------------------------------------
	my $pdf = pdf_file("", "create");

	# --------------------------------------------------
	# This is the main loop. It's executed once for each email
	# --------------------------------------------------
	while(! $mbox->end_of_file() )
	{

		# last if($email_count > $testlimit);

		logging("VERBOSE", "Start Parsing Email '$email_count'");

		# Fetch Email Content
		my $content = $mbox->read_next_email();

		# Check Options (testlimit) for debugging
		if($testlimit > 0) {

			if($start > 0 && $end > 0 ) {

				# process
				if($email_count >= $start && $email_count <= $end ) {

					logging("VERBOSE", "$start <= '$email_count' > $end");
				}
				# skip processing
				else {

					logging("VERBOSE", "skip Email '$email_count' reached testlimit");
					$email_count++;
					next;
				}

				last if($email_count > $end);
			}
			else {

				# stop processing
				logging("VERBOSE", "Stop processing ..");
				last if($email_count > $testlimit);
			}
		}

		my $parser = new MIME::Parser;

		$parser->ignore_errors(0);
		$parser->output_to_core(0);

		### Tell it where to put things:
		$parser->output_under("/tmp");

		my $entity = $parser->parse_data($content);
		my $header = $entity->head;

		# Sanity checks
		next if ($header->get('From') =~ /facebook/);

		my $error = ($@ || $parser->last_error);

		handle_mime_body($email_count,$entity);
		pdf_add_email($pdf, $header);

		$email_count++;
	}

    pdf_file($pdf, "close");
}

elsif($type eq "imap") {
    
	logging("VERBOSE", "type: imap\n");
   
	# connect to imap server
	my $imap = gmail($oauth_token, $username); 

	my $folder = "Inbox";
	$imap->exists($folder) or warn "$folder not found: $@\n";
	my $msgcount = $imap->message_count($folder); 
	defined($msgcount) or die "Could not message_count: $@\n";
	print "msg count = ", $msgcount, "\n";
	
	$imap->select($folder) or warn "$folder not select: $@\n";
	my @msgs = $imap->messages() or die "Could not messages: $@\n";

	my $email_count = 1;

	# --------------------------------------------
	# create a pdf file / pdf object $pdf 
	# --------------------------------------------
	my $pdf = pdf_file("", "create");


	my $i;
	foreach $i (@msgs)
	{
	

		handle_testlimit($i, $testlimit, $start, $end);	

		logging("VERBOSE", "IMAP Message $i from $msgcount");
	
		my $content = $imap->message_string($i);
		
		my $parser = new MIME::Parser;

                $parser->ignore_errors(0);
                $parser->output_to_core(0);

                ### Tell it where to put things:
                $parser->output_under("/tmp");

                my $entity = $parser->parse_data($content);
                my $header = $entity->head;

                # Sanity checks
                next if ($header->get('From') =~ /facebook/);

                my $error = ($@ || $parser->last_error);

                handle_mime_body($email_count,$entity);
                pdf_add_email($pdf, $header);

		$email_count++;
	}

    	pdf_file($pdf, "close");
	
}
else {
   
	print "Error: wrong type '$type'\n";
 	print "Please choose --type imap|mbox\n";
}
exit;

# --------------------------------------
# Handle Testlimit
# --------------------------------------
sub handle_testlimit {

		my ($msg, $testlimit, $start, $end) = @_;

		# Check Options (testlimit) for debugging
		if($testlimit > 0) {

			if($start > 0 && $end > 0 ) {

				# process
				if($msg >= $start && $msg <= $end ) {

					logging("VERBOSE", "$start <= '$msg' > $end");
				}
				# skip processing
				else {

					logging("VERBOSE", "skip Email '$msg' reached testlimit");
					$msg++;
					next;
				}

				last if($msg > $end);
			}
			else {

				# stop processing
				logging("VERBOSE", "Stop processing ..");
				last if($msg > $testlimit);
			}
		}
}

# --------------------------------------------------------
# Handle Body  
# --------------------------------------------------------
sub handle_mime_body {
	
	my $email_count = shift;
	my $entity 	= shift;

	my $plain_body 	= "";
	my $html_body 	= "";
	my $content_type;

	# erase global array content
	@text	= ();
	@images = ();

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
	
			# For "singlepart" types (text/*, image/*, etc.), the unencoded body data is referenced 
			# via a MIME::Body object, accessed via the bodyhandle() method
			if($ct =~ "text/plain") {
		
				# -----------------------------------	
				# Get the text as list
				# -----------------------------------	
				my @lines = $subentity->bodyhandle->as_lines;
			
				foreach(@lines) {
		
					$_ =~ s/\r\n//;	
					$_ =~ s/\n//;	
					
					if ( defined $_ && length($_) > 0) {

						push(@text, $_);	
						logging("VERBOSE", "Part '$i' - Adding Content Type '$ct' '$_'");					
					}
				}
			}

			if($ct =~ "image") {
			
				my $path = $subentity->bodyhandle->path;
	
		
				my $image = Image::Magick->new(magick=>'JPEG');
				$image->Read($path);

				my $width  = $image->Get('width');	
				my $height = $image->Get('height');	

				logging("VERBOSE", "Part '$i' - Size '$width' x '$height' Adding Content Type '$ct' '$path' ");					
				# Todo: Change to hash and add Image Size
				push(@images, $path);

				

			}
			if($ct =~ "text/html") {

				logging("VERBOSE", "Part $i - Type '$ct'");
			}

			if($ct =~ "video") {

				logging("VERBOSE", "Part $i - Type '$ct'");
			}
		}

	}
	else {

		logging("INFO", "No Body-Part found");
		return 0;
	}

	# Return array be reference
	return 1;
}

# --------------------------------------------------------
# Handle PDF
# --------------------------------------------------------
sub pdf_file {
	
	
	my $pdf  = shift;
	my $task = shift;
	
	### FIXME: filename for imap
	my $filename = "default";
	( $filename ) = $mboxfile =~ /.*\/(.*)\.mbox/ if($mboxfile);
	$filename = $path . $filename . ".pdf";
	

	# ---------------------------------------------------
	# Create PDF object
	# ---------------------------------------------------
	if($task eq "create") {

		my $pdf;
		
		logging("DEBUG", "creating PDF '$filename'");
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

	my $pdf		= shift;
	my $header 	= shift;

	# get email headers
	my $subject = $header->get('Subject');
	my $to = $header->get('To');
	my $from = $header->get('From');
	my $date = $header->get('Date');
	my $contenttype = $header->get("Content-Type");

	# delete newlines
	chomp($to);
	chomp($from);
	chomp($date);
	chomp($contenttype);
	
	# Convert Date
	# Fix Me
	my ($ss,$mm,$hh,$day,$month,$year,$zone) = strptime($date);
	$date = sprintf("%s.%s.%s %s:%s", $day, $month, $year + 1900, $hh, $mm);

	# Logging
	logging("VERBOSE", "'$date' Email from '$from'");

	# 72 DPI -> 595 x 842
	my $a4 = $pdf->new_page('MediaBox' => $pdf->get_page_size('A4'));

	# Add a page which inherits its attributes from $a4
  	my $page = $a4->new_page;
 
	# Prepare a font
  	my $f1 = $pdf->font('BaseFont' => 'Times-Roman');
	
	# Mail Header Information
  	$page->string($f1, 9, 1, 780, handle_text($page, $f1, "$date: '$from'") );
	
	# print subject
	if($subject) {
		
		chomp($subject);
 
		# decode subject 
		if(! $subject =~ /.*(utf-8|utf8).*/) {

			my $decoded = decode_mimewords($subject);

			# Fix encoding
			$subject = $decoded;

			logging("DEBUG", "Subject encoding is utf8 - '$subject'");
		}

		$page->line(1, 770, 595, 770);
		$page->string($f1, 9, 1, 760, handle_text($page, $f1, $subject) );
	
		logging("VERBOSE", "Subject: '$subject'");
	}

	# print line
	$page->line(1, 750, 595, 750);

	# ----------------------------------------------------------------
	# ContentText
	# ----------------------------------------------------------------
	my $content = "";

	# Get Text-Element and add to PDF
	foreach(@text) {

		next if($_ eq "delete");
		
		my $text = handle_text($page, $f1, $_);
		
		logging("VERBOSE", "Text: $text");	
		$content = $content . decode_mimewords($text) . "\r\n";
	}

	if(length($content) > 0) {

	  	$page->string($f1, 9, 1, 720, $content);
	}
	
	# print line
	$page->line(1,700, 595, 700);

	# --------------------------------------------------------
	# TODO: check orientation of image
	#       -> AUTO ROTATION
	# --------------------------------------------------------
	my $image = Image::Magick->new(magick=>'JPEG');
	$image->set(verbose=>'true') if($verbose);
	
	# --------------------------------------------------------
	# Set Pics to PDF	
	# --------------------------------------------------------
	my $arrSize = @images;
	my $file = "/tmp/123456789.jpg";
	my $x;


	# Image Position
	my $xpos = 0;
	my $ypos = 0;
	
	# Single Image Email
	if($arrSize == 1) {

		my $geometry;
		
		# Image Size
		$image->Read($images[0]);
		my $w = $image->Get("width");
		my $h = $image->Get("height");

		# --------------------------------------------------------
		# Do not resize, resolution is to small
		# --------------------------------------------------------
		if($w < 500 && $h < 600) {

			$geometry = sprintf("%sx%s", $w, $h);
		}
		# --------------------------------------------------------
		# Resize resolution is large
		# --------------------------------------------------------
		else {

			$geometry = "500x600";
		}
		$image->AutoOrient();
		$image->Resize( geometry => $geometry );
		$w = $image->Get("width");
		$h = $image->Get("height");
		$x = $image->Write($file);

		$xpos = 10;
		$ypos = 600 - $h;
	
		logging("VERBOSE", "Position w '$w' h '$h' x '$xpos' y '$ypos'");
	
	}
	# Multi Image Email
	elsif ($arrSize > 1) {

		foreach(@images) {

			if($_ =~ /PNG/) {

				logging("VERBOSE", "skip PNG '$_'");
				next;
			}
			
			logging("VERBOSE", "Read file '$_'");
			$image->Read($_);
			$image->AutoOrient();
		}

		my $tile = "";
		my $geometry = "100x100";

		if($arrSize == 2) {

			$geometry = "250x300";
			$tile = "2x";

			$xpos = 10;
			$ypos = 100;
		}
		elsif($arrSize == 3) {

			$geometry = "250x300";
			$tile = "2x";
			
			$xpos = 10;
			$ypos = 100;
		}
		elsif($arrSize == 4) {

			$geometry = "250x300";
			$tile = "2x2";
			
			$xpos = 10;
			$ypos = 100;
		}
		elsif($arrSize == 5) {

			$geometry = "125x150";
			$tile = "3x2";
			
			$xpos = 10;
			$ypos = 100;
		}
		elsif($arrSize == 6) {

			$geometry = "125x150";
			$tile = "3x2";
			
			$xpos = 10;
			$ypos = 100;
		}

		# Image Montage
		logging("VERBOSE", "!!!!!Multi Image Email -> Montage");
		my $montage = $image->Montage(background => "white", borderwidth => "0", geometry => $geometry, tile => $tile);
		$x = $montage->Write('jpg:'.$file);
	}
	else {

		logging("VERBOSE", "No Images found");
		return 0;
	}

	my $jpg = $pdf->image($file);
	$page->image( 'image' => $jpg, 'xpos' => $xpos, 'ypos' => $ypos );

	unlink($image);
	unlink($file);
	return 0;
}

# --------------------------------------------------------
# Position of the image
# Todo: BIN Packing 
# 
# 595x600 is for pics
# 
# --------------------------------------------------------
sub image_position {

	my ($arrSize, $count, $width, $height) = @_;

	my $xpos = 35;
	my $ypos = 200;

	if($width > 595) {

		$xpos = 0;
	}
	if($width > 600) {

		$ypos = 0;
	}

	$xpos = $xpos + 200 if($count > 1);

	logging("VERBOSE", "Image Position arrSize '$arrSize' count '$count' x '$xpos' y '$ypos'");

	return $xpos, $ypos;
}

# --------------------------------------------------------
# handle_text  
# --------------------------------------------------------
sub handle_text {

	my ($page, $font, $text) = @_;

	# delete iPhone default footer
	if($text =~ /.*meinem iPhone gesendet.*/ ) {

		logging("VERBOSE", "Found iPhone default footer");
		$text =~ s/Von meinem iPhone gesendet//g;
	}

	my $width = $page->string_width($font, $text);
	logging("VERBOSE", "Width($width) -> '$text'");

	# encoding magic
	utf8::decode($text);

	return $text;

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
	elsif ($LEVEL eq "ERROR") {

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

# --------------------------------------------------------
# gmail IMAP connection
# --------------------------------------------------------
sub gmail {
    
	my ($oaut_token, $username) = @_;

	my $oauth_sign = encode_base64("user=". $username ."\1auth=Bearer ". $oauth_token ."\1\1", '');
	# detail: https://developers.google.com/google-apps/gmail/xoauth2_protocol

	my $imap = Mail::IMAPClient->new(
			Server	=>	'imap.googlemail.com',
			Port	=>	993,
			Ssl		=> 1,
			Uid		=> 1,
			Debug		=> $debug,
			) or die('Can\'t connect to imap server.');

	# DIGEST-MD5
	$imap->authenticate('XOAUTH2', sub { return $oauth_sign } ) or die("Auth error (hm ..): ". $imap->LastError);

	return $imap;


}

