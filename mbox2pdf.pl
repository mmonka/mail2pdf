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
my $start = 0;
my $end = 0;
my $tmp_dir_hash;

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

# Mediabox size in Percent of Page
my $MEDIABOX_BOTTOM = $size_y - ($size_y * 0.05);
my $MEDIABOX_HEIGHT = ($size_y * 0.10);

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
	  ) # flag
or die("Error in command line arguments\n");

if(!$type or $help) {

	print "./mbox2pdf --help\n\n";
	print "--mboxfile=FILE              choose mbox file\n";
	print "--verbose                    enable verbose logging\n";
	print "--debug                      enable debugging\n";
    	print "--type (mbox|imap|s3mount)       choose whether you want to use a local mbox file,a remote imap account or a directory with files per each email\n";
	print "--testlimit=Start(,End)      choose at which position you want to start to generate the pdf file\n";
	exit;
}

print Dumper \%config if($verbose);

# Some Logging
logging("VERBOSE", "Size: x: '$size_x' y: '$size_y' Mediabox: '$MEDIABOX_HEIGHT' DPI: '".DPI."'");

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
		pdf_add_email($pdf, $header, $email_count);

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
	logging("VERBOSE", "msg count = '$msgcount'");
	
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
                pdf_add_email($pdf, $header, $i);

		$email_count++;
	}

    	pdf_file($pdf, "close");
}
elsif($type eq "s3mount") {

	my $dir = sprintf("/mnt/s3/%s/", $hash);

	logging("VERBOSE", "opening $dir. Looking for files");
	opendir my $mount, $dir or die "Cannot open directory: '$!' ($dir)";
	my @files = readdir $mount;
	closedir $mount;

	# --------------------------------------------------
	# value for logging
	# --------------------------------------------------
	my $email_count = 1;

	# --------------------------------------------
	# create a pdf file / pdf object $pdf 
	# --------------------------------------------
	my $pdf = pdf_file("", "create");

	my $parser = new MIME::Parser;

	$parser->ignore_errors(0);
	$parser->output_to_core(0);
	
	### Tell it where to put things:
	$parser->output_under("/tmp");
	
	foreach(@files){
		if (-f $dir . "/" . $_ ){

			logging("VERBOSE",  $_ . "   : file\n");
			
			# File
			my $file = $dir . "/" . $_;

			# Handler
		        my $entity = $parser->parse_open($file);
			my $header = $entity->head;

			# Sanity checks
			next if ($header->get('From') =~ /facebook/);

			my $error = ($@ || $parser->last_error);

			handle_mime_body($email_count,$entity);
			pdf_add_email($pdf, $header, $email_count);

			$email_count++;

		}elsif(-d $dir . "/" . $_){
			logging("VERBOSE", $_ . "   : folder\n");
			next;
		}else{
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
		rmdir "/tmp/".$tmp_dir_hash;

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
	
	logging("VERBOSE", "'$date' Email from '$from'");
	# Convert Date
	# Fix Me
	my ($ss,$mm,$hh,$day,$month,$year,$zone) = strptime($date);
	$date = sprintf("%s.%s", $day, $month);
	$year = $year + 1900;

	# Logging
	logging("VERBOSE", "'$date' Email from '$from'");

	# Add new Page 
	my $page = $pdf->page;

	$page->mediabox( $size_x, $size_y );
	$page->bleedbox(  5/mm,   5/mm,  100/mm,  143/mm);
	$page->cropbox( 7.5 / mm, 7.5 / mm, 97.5 / mm, 140.5 / mm );
	$page->artbox  ( 10/mm,  10/mm,   95/mm,  138/mm);

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

	my $blue_box = $page->gfx;
	$blue_box->fillcolor('orange');
	$blue_box->rect( 0 ,            	# left
			$MEDIABOX_BOTTOM,   # bottom
			$size_x,       		# width
			$MEDIABOX_HEIGHT);      # height
	$blue_box->fill;

	if($verbose || $debug) {

		my $headline_page_count = $page->text;
		$headline_page_count->font( $font{'Helvetica'}{'Bold'}, ($MEDIABOX_HEIGHT * 0.3));
		$headline_page_count->fillcolor('black');
		$headline_page_count->translate( 40  , $size_y - ($MEDIABOX_HEIGHT * 0.3));
		$headline_page_count->text_center($email_count);
	}
	
	# Year
	my $headline_year = $page->text;
	$headline_year->font( $font{'Helvetica'}{'Bold'}, ($MEDIABOX_HEIGHT * 0.3));
	$headline_year->fillcolor('black');
	$headline_year->translate( $size_x - ($size_x * 0.01)  , $size_y - ($MEDIABOX_HEIGHT * 0.3));
	$headline_year->text_right($year);

	# From
	my $headline_text = $page->text;
	$headline_text->font( $font{'Helvetica'}{'Bold'}, ($MEDIABOX_HEIGHT * 0.10));
	$headline_text->fillcolor('white');
	$headline_text->translate( $size_x - ($size_x * 0.20) , $size_y - ($MEDIABOX_HEIGHT * 0.15));
	$headline_text->text_right("von " . $from);


	# --------------------------------------	
	# print subject
	# --------------------------------------	
	if($subject) {
		
		chomp($subject);
 
		# decode subject 
		if( $subject =~ /.*(utf-8|utf8).*/) {

			my $decoded = decode_mimewords($subject);

			# Fix encoding
			$subject = $decoded;

			logging("VERBOSE", "Subject encoding is utf8 .. decoded - '$subject'");
		}

		my $subject_text = $page->text;
		$subject_text->font( $font{'Helvetica'}{'Bold'}, ($MEDIABOX_HEIGHT * 0.15) );
		$subject_text->fillcolor('white');
		$subject_text->translate( $size_x - ($size_x * 0.15)  , $size_y - ($MEDIABOX_HEIGHT * 0.4) );
		$subject_text->text_right(decode("utf8", $subject) . " am " . $date);
	
		logging("VERBOSE", "Subject: '$subject'");
	}

	# ----------------------------------------------------------------
	# ContentText
	# ----------------------------------------------------------------
	if(@text > 0 ) {

			my $content = "";

			# Get Text-Element and add to PDF
			foreach(@text) {

				next if($_ eq "delete");

				my $text = handle_text($_);

				logging("VERBOSE", "Text: $text");	
				$content = $content . decode_mimewords($text) . "\r\n";
			}

			if(length($content) > 0) {

				my $message_text = $page->text;
				$message_text->font( $font{'Helvetica'}{'Bold'}, 6 / pt );
				$message_text->fillcolor('white');
				$message_text->translate( 250 , $size_y - (60 * mm) );
				$message_text->text_right($content);
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

	$tmp_dir_hash = md5_hex( $subject );
	mkdir "/tmp/" . $tmp_dir_hash;

	my $file = "/tmp/" . $tmp_dir_hash . "/" . md5_hex($from.$date) . ".jpg";
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
	my $geometry = sprintf("%sx%s", $size_x, $size_y - $MEDIABOX_HEIGHT) ;
	
	# Single Image Email
	if($arrSize == 1) {

		# Get Image
		$image->Read($images[0]);
		$image->AutoOrient();
		$image->Set(density => DENSITY);
		$image->Resize( geometry => $geometry, density => DENSITY, compress => 'none' );
		$w = $image->Get("width");
		$h = $image->Get("height");
		$d = $image->Get("density");
		$x = $image->Write('jpg:'.$file);
		logging("VERBOSE", "Picture size  w '$w' h '$h' d '$d', PDF Size $size_x $size_y");
	}
	# Multi Image Email
	elsif ($arrSize > 1) {

		if($arrSize == 2) {
		
			$geometry = sprintf("%sx%s", $size_x , ($size_y / 2) - $MEDIABOX_HEIGHT);
			$tile = "1x2";

		}
		elsif($arrSize == 3) {

			$geometry = sprintf("%sx%s", $size_x / 2 , ($size_y / 2) - $MEDIABOX_HEIGHT);
			$tile = "2x2";
		}
		elsif($arrSize == 4) {

			$geometry = sprintf("%ix%i", $size_x / 2 , ($size_y / 2) - $MEDIABOX_HEIGHT);
			$tile = "2x2";
			
		}
		elsif($arrSize == 5) {

			$geometry = sprintf("%sx%s", $size_x / 3 , ($size_y / 2) - $MEDIABOX_HEIGHT);
			$tile = "3x2";
			
		}
		elsif($arrSize == 6) {

			$geometry = sprintf("%sx%s", $size_x / 3 , ($size_y / 3) - $MEDIABOX_HEIGHT);
			$tile = "3x";
		}
		
		foreach(@images) {

			if($_ =~ /PNG/) {

				logging("VERBOSE", "skip PNG '$_'");
				next;
			}
			
			logging("VERBOSE", "Prepair file '$_' .... ");
			$image->Read($_);
			$image->Set(density => DENSITY);
			$w = $image->Get("width");
			$h = $image->Get("height");
			$d = $image->Get("density");
			logging("VERBOSE", "Picture size w '$w' h '$h' d '$d'");
		}

		# Image Montage
		# Geometry: It defines the size of the individual thumbnail images, and the spacing between them
		$image->AutoOrient();
		my $montage = $image->Montage(geometry => $geometry , tile => $tile, density => DENSITY, quality => 100, compress => 'none'  );
		$x = $montage->Write('jpg:'.$file);
		
		logging("VERBOSE", "Multi Image Email -> Montage , Size Y: '$size_y' Geometry: '$geometry' Tile: '$tile'");

		# for calculate center position
		$w = $size_x;
		$h = $size_y;
	}
	else {

		logging("VERBOSE", "No Images found");
		return 0;
	}

	logging("VERBOSE", "File $file");

	# Add photo to pdf page
	my $photo = $page->gfx;

	# check, that file exists
	if (-e $file) {

		# Calculate xi/y Position, so Image is "center"
		my $position_x = int ( $size_x - $w ) / 2; 
		my $position_y = 5;		

		if($h < $size_y - (120 * mm) ) {
			$position_y = ( ( $size_y - (120 * mm) ) - $h) / 2;
		}

		my $photo_file = $pdf->image_jpeg($file);
		logging("VERBOSE", "Write '$photo_file' to pdf x: '$position_x', y: '$position_y'");
		$photo->image( $photo_file, $position_x, $position_y );
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

	# delete iPhone default footer
	if($text =~ /.*meinem iPhone gesendet.*/ ) {

		logging("VERBOSE", "Found iPhone default footer");
		$text =~ s/Von meinem iPhone gesendet//g;
	}

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

