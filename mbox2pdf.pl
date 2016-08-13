#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;

use Mail::IMAPClient;
use Mail::Mbox::MessageParser;
use MIME::Parser;
use MIME::Words qw(:all);
use MIME::Body;
use MIME::Base64;

use Date::Parse;
use Getopt::Long;

use PDF::API2;

use Digest::MD5 qw(md5_hex); 

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
my $hash;
my $help;
my $testlimit = 0;
my $onlyyear;
my $start = 0;
my $end = 0;
my $text_length = 0;

# where to save tmp files
our $tmp_dir_hash;

# Constant for Page size
use constant DPI => 300;
use constant mm => 25.4 / DPI;  # 25.4 mm in an inch, 72 points in an inch
use constant in => 1 / DPI;     # 72 points in an inch
use constant pt => 1;           # 1 point
use constant DENSITY => "300x300"; 		# DPI 


# Page Size
use constant A4_x => 210 / mm;        # x points in an A4 page ( 595.2755 )
use constant A4_y => 297 / mm;        # y points in an A4 page ( 841.8897 )
use constant A6_x => 105 / mm;        # x points in an A6 page ( 595.2755 )
use constant A6_y => 148 / mm;        # y points in an A6 page ( 419.53 )

# Define Page size
my $size_x = A4_x;
my $size_y = A4_y;

# Draw a Infobox with Background, or just a line
my $ADD_INFOBOX    = "true";
# Infobox size in Percent of Page
my $INFOBOX_BOTTOM = $size_y - ($size_y * 0.05);
my $INFOBOX_HEIGHT = $size_y - $INFOBOX_BOTTOM;

# buffer, so resized pic placed well on content part
my $x_buffer = 50;
my $y_buffer = 50;

# some arrays
our @text;
our @images;

# Include some vars from config.pl 
my %config = do '/Users/markus/git/mail2pdf/config.pl';

my $username = $config{username} or die("missing username from config.pl");
my $oauth_token = $config{oauth_token} or die("missing oauth_token from config.pl");
my $path = $config{path} or die("missing path from config.pl");
my $filename = $config{filename} or die("missing filename");
my $s3mount = $config{s3mount};

# --------------------------------------------------
# Getopt definition
# --------------------------------------------------
GetOptions(	"mboxfile=s" => \$mboxfile, # string
    		"verbose" => \$verbose,
    		"debug" => \$debug,
            	"help" => \$help,
            	"type=s" => \$type,
		"hash=s" => \$hash,
		"filename=s" => \$filename,
		"path=s" => \$path,
            	"testlimit=s" => \$testlimit,
            	"onlyyear=i" => \$onlyyear,
	  ) # flag
or die("Error in command line arguments\n");

if(!$type or $help) {

	print "./mbox2pdf --help\n\n";
	print "--mboxfile=FILE              choose mbox file\n";
	print "--verbose                    enable verbose logging\n";
	print "--debug                      enable debugging\n";
    	print "--type (mbox|imap|s3mount)       choose whether you want to use a local mbox file,a remote imap account or a directory with files per each email\n";
	print "--testlimit=Start(,End)      choose at which position you want to start to generate the pdf file\n";
	print "--onlyyear=YEAR		    only print YEAR Content to PDF\n";
	exit;
}

print Dumper \%config if($verbose);

# Some Logging
logging("VERBOSE", "Size: x: '$size_x' y: '$size_y' Infobox Bottom: $INFOBOX_BOTTOM Infobox Height: '$INFOBOX_HEIGHT' DPI: '".DPI."'");

# Testlimit is set
if($testlimit =~ /([\d]+),([\d]+)/) {

	$start = $1;
	$end   = $2;
	$testlimit = $2;

	if($start > $end) {
	
		$end = $start + $end;
		logging("INFO", "End looks like an Offset. Recalculate end ($end)");
	}	
	
	logging("VERBOSE", "Testlimit between Message '$start' '$end'");
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
		pdf_add_email($pdf, $header, $email_count);

		$email_count++;
	}

    pdf_file($pdf, "close");
}

elsif($type eq "imap") {
    
	logging("VERBOSE", "type: imap\n");
   
	# connect to google imap server
	my $imap = gmail($oauth_token, $username); 

	# choose label/folder
	my $folder = "Inbox";
	$imap->exists($folder) or warn "$folder not found: $@\n";

	# select folder	
	$imap->select($folder) or warn "$folder not select: $@\n";
	
	# how many messages are their?
	my $msgcount = $imap->message_count($folder); 
	defined($msgcount) or die "Could not message_count: $@\n";
	logging("VERBOSE", "msg count = '$msgcount'");
	
	# --------------------------------------------
	# create a pdf file / pdf object $pdf 
	# --------------------------------------------
	my $pdf = pdf_file("", "create");

	# import messages
	my @msgs = $imap->messages() or die "Could not messages: $@\n";

	# generate a /tmp/ subdirectory .. 
	$tmp_dir_hash = md5_hex( $imap . $pdf . $msgcount );
	mkdir "/tmp/" . $tmp_dir_hash;

	logging("VERBOSE", "create tmp sub dirctory /tmp/$tmp_dir_hash");

	# loop 
	my $msg_cnt = 0;
	foreach my $i (@msgs)
	{
		# increase email/message count
		$msg_cnt++;
	
		logging("DEBUG", "IMAP Message $msg_cnt from $msgcount");
		
		# if in testlimit mode, check, whether to add this email
		# or not
		my $res = handle_testlimit($msg_cnt, $testlimit, $start, $end);	
		
		# if handle_testlimit skips email, go to next one
		next if ($res == 0);

		# if in onlyyear mode, check if email year match
		my $date = $imap->get_header($i, "Date");
		
		# return 0: ignore | return 1: match
		my $res_hoy = handle_option_year($onlyyear, $date);
		
		if($res_hoy == 0) {

			logging("DEBUG", "handle_option_year: ignore email based on year ($onlyyear)");
			next;
		}

		# get message content	
		my $content = $imap->message_string($i);
		
		# start MIME Parser
		my $parser = new MIME::Parser;

                $parser->ignore_errors(0);
                $parser->output_to_core(0);

                # tell it where to put things
                $parser->output_under("/tmp");

                my $entity = $parser->parse_data($content);
                my $header = $entity->head;

                # Sanity checks
		# e.g. if email from facebook -> ignore it
                next if ($header->get('From') =~ /facebook/);

		# if error, get it
                my $error = ($@ || $parser->last_error);

		# handle body
                handle_mime_body($i,$entity);

		# add email to pdf
                pdf_add_email($pdf, $header, $msg_cnt);


	}

    	pdf_file($pdf, "close");
}
elsif($type eq "s3mount") {

	my $dir = sprintf("/mnt/s3/%s/", $hash);

	logging("VERBOSE", "opening $dir. Looking for files");
	opendir my $mount, $dir or die "Cannot open directory: '$!' ($dir)";
	my @files = readdir $mount;
	closedir $mount;

	# how many messages are their?
	my $msgcount = @files; 
	defined($msgcount) or die "Could not message_count: $@\n";
	logging("VERBOSE", "msg count = '$msgcount'");
	
	# --------------------------------------------------
	# value for logging
	# --------------------------------------------------
	my $msg_cnt = 0;

	# --------------------------------------------
	# create a pdf file / pdf object $pdf 
	# --------------------------------------------
	my $pdf = pdf_file("", "create");

	# generate a /tmp/ subdirectory .. 
	$tmp_dir_hash = md5_hex( $mount . $pdf . $hash );
	mkdir "/tmp/" . $tmp_dir_hash;
	
	# Parser Object
	my $parser = new MIME::Parser;

	$parser->ignore_errors(0);
	$parser->output_to_core(0);
	
	### Tell it where to put things:
	$parser->output_under("/tmp");

	# walk through the array of files	
	foreach(@files){

		if (-f $dir . "/" . $_ ){

	
			# increase email/message count
			$msg_cnt++;
			
			# if in testlimit mode, check, whether to add this email
			# or not
			my $res = handle_testlimit($msg_cnt, $testlimit, $start, $end);	

			# if handle_testlimit skips email, go to next one
			next if ($res == 0);

			logging("VERBOSE",  $_ . "   : file\n");
			
			# which file to work on, add dir to loop/foreach value
			my $file = $dir . "/" . $_;

			# Handler
		        my $entity = $parser->parse_open($file);
			my $header = $entity->head;

			# Sanity checks
			next if ($header->get('From') =~ /facebook/);

			my $error = ($@ || $parser->last_error);

			handle_mime_body($msg_cnt, $entity);
			pdf_add_email($pdf, $header, $msg_cnt);

		} elsif(-d $dir . "/" . $_){
			logging("VERBOSE", $_ . "   : folder\n");
			next;
		} else{
			logging("VERBOSE", $_ . "   : other\n");
			next;
		}
	}


    	pdf_file($pdf, "close");

}
else {
   
	print "Error: wrong type '$type'\n";
 	print "Please choose --type imap|mbox\n";
}

print "File was generated. Have fun\n";
exit;

# --------------------------------------
# Handle year if option for a special
# year is set 
# --------------------------------------
sub handle_option_year {

	my ($onlyyear, $date) = @_;

	# extract year from email date line (RFC822 format)
	my ($ss,$mm,$hh,$day,$month,$year,$zone) = strptime($date);

	# Have to add offset 1900
	$year = $year + 1900;
	
	if($onlyyear && $onlyyear != $year ) {

		logging("DEBUG", "option 'onlyyear - $onlyyear' is active and this email is from $year - skip");
		return 0;
	}

	return 1;
}

# --------------------------------------
# Handle Testlimit
# --------------------------------------
sub handle_testlimit {

		my ($msg, $testlimit, $start, $end) = @_;

		# Check Options (testlimit) for debugging
		if($testlimit > 0 ) {

			if($start > 0 && $end > 0 ) {

				# process
				if($msg >= $start && $msg <= $end ) {

					logging("DEBUG", "testlimit ($start,$end) - process email number '$msg'");
					return 1;
				}
				# skip processing
				else {

					logging("DEBUG", "testlimit ($start,$end) - skip email number '$msg'");
					return 0;
				}

				last if($msg > $end);
			}
			else {

				# stop processing
				logging("VERBOSE", "Stop processing .. '$msg > $testlimit' ");
				
				if($msg > $testlimit) {
					return 0;
				}
			}
		}
		
		return 1;
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
		
					my $text = handle_text($_);

					if(defined $text && length($text) > 0) {
						
						push(@text, $text);	
						logging("VERBOSE", "Part '$i' - Adding Content Type '$ct' '$text'");					
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

	# Values are included in config.pl	
	my $filename =  $path . $filename;

	# ---------------------------------------------------
	# Create PDF object
	# ---------------------------------------------------
	if($task eq "create") {

		my $pdf;

		logging("VERBOSE", "create file '$filename'");
		logging("DEBUG", "creating PDF '$filename'");
		
		$pdf = PDF::API2->new( -file => "$filename" );

		return $pdf;
	}
	elsif($task eq "close") {

		$pdf->save;
		$pdf->end;

		logging("VERBOSE", "Remove /tmp/" . $tmp_dir_hash);
		rmdir "/tmp/".$tmp_dir_hash or warn("Could not delete, not empty");

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
	my $email_count = shift;

	# get date headers
	my $date = $header->get('Date');

	# Convert Date
	# the year is the number of years since 1900, and the month is zero-based (0 = January)
	my ($ss,$mm,$hh,$day,$month,$year,$zone) = strptime($date);
	$date = sprintf("%d.%d", $day, $month + 1);
	$year = $year + 1900;


	# get more headers
	my $subject = $header->get('Subject');
	my $to = $header->get('To');
	my $from = $header->get('From');
	my $contenttype = $header->get("Content-Type");
	
	# delete newlines
	chomp($to);
	chomp($from);
	chomp($date);
	chomp($contenttype);
	

	# Logging
	logging("VERBOSE", "'$date' Email from '$from'");

	# Add new Page 
	my $page = $pdf->page;
	$page->mediabox( $size_x, $size_y );

	# printting details
	#$page->bleedbox(  5/mm,   5/mm,  100/mm,  143/mm);
	#$page->cropbox( 7.5 / mm, 7.5 / mm, 97.5 / mm, 140.5 / mm );
	#$page->artbox  ( 10/mm,  10/mm,   95/mm,  138/mm);

	my %font = (
			Helvetica => {
			Bold   => $pdf->corefont( 'Helvetica-Bold',    -encoding => 'latin1' ),
			Roman  => $pdf->corefont( 'Helvetica',         -encoding => 'latin1' ),
			Italic => $pdf->corefont( 'Helvetica-Oblique', -encoding => 'latin1' ),
			},
			Times => {
			Bold   => $pdf->corefont( 'Times-Bold',   -encoding => 'latin1' ),
			Roman  => $pdf->corefont( 'Times',        -encoding => 'latin1' ),
			Italic => $pdf->corefont( 'Times-Italic', -encoding => 'latin1' ),
			},
		   );

	# Make InfoBox variable
	# Add a box with background color
	if($ADD_INFOBOX) {

		my $blue_box = $page->gfx;
		$blue_box->fillcolor('orange');
		$blue_box->rect( 0 ,            	# left
				$INFOBOX_BOTTOM,   # bottom
				$size_x,       		# width
				$INFOBOX_HEIGHT);      # height
		$blue_box->fill;

	# or just space with a line
	} else {

		my $line = $page->gfx;
		$line->strokecolor('black');
		$line->linewidth(5);
		$line->move( 0, $INFOBOX_BOTTOM );
		$line->line( $size_x, $INFOBOX_BOTTOM );
		$line->stroke;

	}

	# Debug/Verbose - Mode: print Email-Number on Page	
	if($verbose || $debug) {

		my $headline_page_count = $page->text;
		$headline_page_count->font( $font{'Helvetica'}{'Bold'}, 40/pt);
		$headline_page_count->fillcolor('black');
		$headline_page_count->translate( $size_x * 0.05  , $size_y - ($INFOBOX_HEIGHT * 0.6) );
		$headline_page_count->text_center($email_count);
	}
	
	# Headline Information

	#
	# Todo: calculate the position new/correct based on font size etc
	#
	
	# Date
	my $headline_date = $page->text;
	$headline_date->font( $font{'Helvetica'}{'Bold'}, 50/pt);
	$headline_date->fillcolor('black');
	$headline_date->translate( $size_x * 0.05  , $size_y - ($INFOBOX_HEIGHT * 0.3));
	$headline_date->text_center($date);


	# Year
	my $headline_year = $page->text;
	$headline_year->font( $font{'Helvetica'}{'Bold'}, 50/pt);
	$headline_year->fillcolor('black');
	$headline_year->translate( $size_x - ($size_x * 0.01)  , $size_y - ($INFOBOX_HEIGHT * 0.3));
	$headline_year->text_right($year);

	# --------------------------------------	
	# print subject
	# --------------------------------------	
	if($subject) {
		
		chomp($subject);
 
		# decode subject 
		if( $subject =~ /.*(utf-8|utf8|UTF-8|UTF8).*/) {

			my $decoded = decode_mimewords($subject);

			# Fix encoding
			$subject = $decoded;

			logging("VERBOSE", "Subject encoding is utf8 .. decoded - '$subject'");
		}


		# Todo: move to text_block
		my $subject_text = $page->text;

		# Make subject presenter, if no text is available
		my $size = "60/pt";
		my $translate_x = $size_x * 0.4 + ( length($subject) * 20 );
		my $translate_y = $size_y - ( $INFOBOX_HEIGHT * 0.5 );

		$subject_text->font( $font{'Helvetica'}{'Bold'},$size );
		$subject_text->fillcolor('black');
		$subject_text->translate( $translate_x  , $translate_y );
		$subject_text->text_right(decode("utf8", $subject));
	
		logging("VERBOSE", "Subject: '$subject'");
	}

	# ----------------------------------------------------------------
	# ContentText
	# ----------------------------------------------------------------
	if(@text > 0 ) {

			my $content = "";
			$text_length = 0;

			# Get Text-Element and add to PDF
			foreach(@text) {

				next if($_ eq "delete");

				my $text = handle_text($_);
				
				# check plain/text
				$content = $content . $text . " ";
			}

			logging("VERBOSE", "Text: '$content' length: '" . length($content) . "'");

			$text_length = length($content);

			if($text_length > 0) {

				my $text  = $page->text;

				# Dynamic Font size; depends on text length
				my $fsize = 30/pt; 
				if( $text_length > 400 ) {

					$fsize = 18/pt;
				} 

				$text->font( $font{'Helvetica'}{'Bold'}, $fsize );
				$text->fillcolor('black');
				
				#
				# more information for the values check inside the sub
				#
				#    -x        => $left_edge_of_block,
				#    -y        => $baseline_of_first_line,
				#    -w        => $width_of_block,
				#    -h        => $height_of_block,
		
				my ( $endw, $y_pos, $paragraph ) = text_block(
						$text,
						$content,
						-x        => $size_x * 0.1,
						-y        => $size_y - $INFOBOX_HEIGHT - ($fsize*2),
						-w        => $size_x * 0.8,
						-h        => $INFOBOX_HEIGHT,
						-lead     => 20/pt * 2,
						-parspace => 0/pt,
						-align    => 'left',
						-hang     => "",
						);
	
				# add another line	
				my $line = $page->gfx;
				$line->strokecolor('black');
				$line->linewidth(5);
				$line->move( 0, $INFOBOX_BOTTOM - $INFOBOX_HEIGHT );
				$line->line( $size_x, $INFOBOX_BOTTOM - $INFOBOX_HEIGHT );
				$line->stroke;

				logging("VERBOSE", "Add line: (0, $INFOBOX_BOTTOM - $INFOBOX_HEIGHT) / ($size_x, $INFOBOX_BOTTOM - $INFOBOX_HEIGHT)");

			}

	}
	
	# --------------------------------------------------------
	# TODO: check orientation of image
	#       -> AUTO ROTATION
	# --------------------------------------------------------
	my $image = Image::Magick->new(magick=>'JPEG');
	$image->set(verbose=>'true') if($verbose);
	$image->set(debug=>'true') if($debug);
	$image->set(compression=>'none');
	
	# --------------------------------------------------------
	# Generate perfectly-balanced-photo-gallery	
	# --------------------------------------------------------
	my $arrSize = @images;

	# this will be the montage file
	my $file = "/tmp/" . $tmp_dir_hash . "/" . md5_hex($ss.$from.$date.$subject) . ".jpg";

	my $x;
	my $tile;

	# --------------------------------------------------------
	# Image Position
	# --------------------------------------------------------
	my $xpos = 0;
	my $ypos = 0;
	
	my $w = 0;
	my $h = 0;
	my $d = DENSITY;
 
	# --------------------------------------------------------
	# Resize to fit under the info/mediabox
	# thats why we sub 50 from size_y
	# --------------------------------------------------------
	my $geometry = sprintf("%sx%s", $size_x - $x_buffer, $text_length > 0 ? $INFOBOX_BOTTOM - $INFOBOX_HEIGHT - $y_buffer : $INFOBOX_BOTTOM - $y_buffer) ;
	
	# Single Image Email
	if($arrSize == 1) {

		# Get Image
		$image->Read($images[0]);
		$image->AutoOrient();
		
		$w = $image->Get("width");
		$h = $image->Get("height");

		$image->Set(density => DENSITY);

		# Check, if pic size fits content space
		if( $w > $size_x || $h > ($text_length > 0 ? $INFOBOX_BOTTOM - $INFOBOX_HEIGHT - $y_buffer : $INFOBOX_BOTTOM - $y_buffer ) ) {
	

			logging("VERBOSE", "resize PIC cause width is greater then $size_x" );
			$image->Resize( geometry => $geometry, compress => 'none' );
		}

		# Resized values
		$w = $image->Get("width");
		$h = $image->Get("height");
		
		$x = $image->Write('jpg:'.$file);
	}
	# Multi Image Email
	elsif ($arrSize > 1) {

		my $geo_size_y = ( $text_length > 0 ? $INFOBOX_BOTTOM - $INFOBOX_HEIGHT - $y_buffer : $INFOBOX_BOTTOM - $y_buffer);

		if($arrSize == 2) {
		
			$geometry = sprintf("%sx%s", $size_x , ($geo_size_y)  / 2 );
			$tile = "1x2";

		}
		elsif($arrSize == 3) {

			$geometry = sprintf("%sx%s", $size_x / 2 , ($geo_size_y) / 2);
			$tile = "2x2";
		}
		elsif($arrSize == 4) {

			$geometry = sprintf("%ix%i", $size_x / 2 , ($geo_size_y) / 2);
			$tile = "2x2";
			
		}
		elsif($arrSize == 5) {

			$geometry = sprintf("%sx%s", $size_x / 3 , ($geo_size_y) / 2 );
			$tile = "3x2";
			
		}
		elsif($arrSize == 6 ) {

			$geometry = sprintf("%sx%s", $size_x / 3 , ($geo_size_y) / 2 );
			$tile = "3x";
		}
		elsif($arrSize == 7 || $arrSize == 8) {

			$geometry = sprintf("%sx%s", $size_x / 2 , ($geo_size_y) / 4 );
			$tile = "2x";
		}
		elsif($arrSize == 9 || $arrSize == 10) {

			$geometry = sprintf("%sx%s", $size_x / 2 , ($geo_size_y) / 5 );
			$tile = "2x";
		}
		
		foreach(@images) {

			if($_ =~ /PNG/) {

				logging("INFO", "skip PNG '$_' Email '$email_count'");
				next;
			}
			
			$image->Read($_);
		}

		# Image Montage
		# Geometry: It defines the size of the individual thumbnail images, and the spacing between them
		$image->AutoOrient();
		my $montage = $image->Montage(geometry => $geometry , tile => $tile, density => DENSITY, quality => 100, compress => 'none', border => 0,  bordercolor => 'grey');
		$x = $montage->Write('jpg:'.$file);
		
		# for calculate center position
		$w = $size_x;
		$h = $INFOBOX_BOTTOM - $y_buffer;
	}
	else {

		logging("VERBOSE", "No Images found");
		return 0;
	}


	# Add photo to pdf page
	my $photo = $page->gfx;

	# check, that file exists
	if (-e $file) {

		# Calculate x/y Position, so Image is "center" and fit nicly
		my $position_x = int (($size_x - $w ) / 2); 
		my $position_y = int ( $y_buffer / 2);		

		# Space for PIC(s)
		my $pic_space_y = ($text_length > 0 ? int ($INFOBOX_BOTTOM - $INFOBOX_HEIGHT - $y_buffer) : int ($INFOBOX_BOTTOM - $y_buffer) );
	
		# calculate y position
		if($h < $pic_space_y ) {

			# center for y axis
			$position_y = int ( $pic_space_y - $h) / 2;
			logging("VERBOSE", "Calculate new y position '$position_y' $pic_space_y");
		}

		my $photo_file = $pdf->image_jpeg($file);
		$photo->image( $photo_file, $position_x, $position_y );
		logging("VERBOSE", "Write pic - size_x: '$size_x' size_y: '$size_y' geometry: '$geometry' w: '$w' h: '$h' pos_x: '$position_x', pos_y: '$position_y'");
	}
	else {

		logging("WARING", "Unable to find image file: $!");
	}

	# To delete all the images but retain the Image::Magick object use
	@$image = ();

	return 0;
}

# --------------------------------------------------------
# handle_text  
# --------------------------------------------------------
sub handle_text {

	my ($text) = @_;

	# delete newline, character return
	$text =~ s/\r\n//;	
	$text =~ s/\n//;	

	# delete iPhone default footer
	if($text =~ /.*meinem iPhone gesendet.*/ ||
	   $text =~/.*Gesendet von meinem iPhone.*/
	  ) {

		logging("VERBOSE", "ignore iPhone default footer");
		return undef;
	}

	# encoding magic / result is 0 or 1
	utf8::decode($text);
	# decode_mimewords($test);	

	return $text;
}

# --------------------------------------------------------
# optimize setting the text/subject into a block  
#
# ($width_of_last_line, $ypos_of_last_line, $left_over_text) = text_block(
#
#    $text_handler_from_page,
#    $text_to_place,
#    -x        => $left_edge_of_block,
#    -y        => $baseline_of_first_line,
#    -w        => $width_of_block,
#    -h        => $height_of_block,
#   [-lead     => $font_size * 1.2 | $distance_between_lines,]
#   [-parspace => 0 | $extra_distance_between_paragraphs,]
#   [-align    => "left|right|center|justify|fulljustify",]
#   [-hang     => $optional_hanging_indent,]
#
#);
# --------------------------------------------------------
sub text_block {

    my $text_object = shift;
    my $text        = shift;

    my %arg = @_;

    # Get the text in paragraphs
    my @paragraphs = split( /\n/, $text );

    # calculate width of all words
    my $space_width = $text_object->advancewidth(' ');

    my @words = split( /\s+/, $text );
    my %width = ();
    foreach (@words) {
        next if exists $width{$_};
        $width{$_} = $text_object->advancewidth($_);
    }

    my $endw;

    my $ypos = $arg{'-y'};
    my @paragraph = split( / /, shift(@paragraphs) );

    my $first_line      = 1;
    my $first_paragraph = 1;

    # while we can add another line

    while ( $ypos >= $arg{'-y'} - $arg{'-h'} + $arg{'-lead'} ) {

        unless (@paragraph) {
            last unless scalar @paragraphs;

            @paragraph = split( / /, shift(@paragraphs) );

            $ypos -= $arg{'-parspace'} if $arg{'-parspace'};
            last unless $ypos >= $arg{'-y'} - $arg{'-h'};

            $first_line      = 1;
            $first_paragraph = 0;
        }

        my $xpos = $arg{'-x'};

        # while there's room on the line, add another word
        my @line = ();

        my $line_width = 0;
        if ( $first_line && exists $arg{'-hang'} ) {

            my $hang_width = $text_object->advancewidth( $arg{'-hang'} );

            $text_object->translate( $xpos, $ypos );
            $text_object->text( $arg{'-hang'} );

            $xpos       += $hang_width;
            $line_width += $hang_width;
            $arg{'-indent'} += $hang_width if $first_paragraph;

        }
        elsif ( $first_line && exists $arg{'-flindent'} ) {

            $xpos       += $arg{'-flindent'};
            $line_width += $arg{'-flindent'};

        }
        elsif ( $first_paragraph && exists $arg{'-fpindent'} ) {

            $xpos       += $arg{'-fpindent'};
            $line_width += $arg{'-fpindent'};

        }
        elsif ( exists $arg{'-indent'} ) {

            $xpos       += $arg{'-indent'};
            $line_width += $arg{'-indent'};

        }

        while ( @paragraph
            and $line_width + ( scalar(@line) * $space_width ) +
            $width{ $paragraph[0] } < $arg{'-w'} )
        {

            $line_width += $width{ $paragraph[0] };
            push( @line, shift(@paragraph) );

        }

        # calculate the space width
        my ( $wordspace, $align );
        if ( $arg{'-align'} eq 'fulljustify'
            or ( $arg{'-align'} eq 'justify' and @paragraph ) )
        {

            if ( scalar(@line) == 1 ) {
                @line = split( //, $line[0] );

            }
            $wordspace = ( $arg{'-w'} - $line_width ) / ( scalar(@line) - 1 );

            $align = 'justify';
        }
        else {
            $align = ( $arg{'-align'} eq 'justify' ) ? 'left' : $arg{'-align'};

            $wordspace = $space_width;
        }
        $line_width += $wordspace * ( scalar(@line) - 1 );

        if ( $align eq 'justify' ) {
            foreach my $word (@line) {

                $text_object->translate( $xpos, $ypos );
                $text_object->text($word);

                $xpos += ( $width{$word} + $wordspace ) if (@line);

            }
            $endw = $arg{'-w'};
        }
        else {

            # calculate the left hand position of the line
            if ( $align eq 'right' ) {
                $xpos += $arg{'-w'} - $line_width;

            }
            elsif ( $align eq 'center' ) {
                $xpos += ( $arg{'-w'} / 2 ) - ( $line_width / 2 );

            }

            # render the line
            $text_object->translate( $xpos, $ypos );

            $endw = $text_object->text( join( ' ', @line ) );

        }
        $ypos -= $arg{'-lead'};
        $first_line = 0;

    }
    unshift( @paragraphs, join( ' ', @paragraph ) ) if scalar(@paragraph);

    return ( $endw, $ypos, join( "\n", @paragraphs ) )

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

