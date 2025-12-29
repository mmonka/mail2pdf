#!/usr/bin/perl

use strict;
use warnings;
use lib "$ENV{HOME}/perl5/lib/perl5";
use Data::Dumper;

# Mail and MIME Handling
use Mail::IMAPClient;
use Mail::Mbox::MessageParser;
use MIME::Parser;
use MIME::Words qw(:all);
use MIME::Body;
use MIME::Base64;

# Other stuff
use Date::Parse;
use Getopt::Long;
use File::Path;
use Digest::MD5 qw(md5_hex); 

# PDF stuff
use PDF::API2;
use PDF::TextBlock;

# Encoding
use URI::Escape;
use Encode;
use utf8;

# Image Manipulatin
use Image::Magick;

binmode STDOUT, ":encoding(UTF-8)";
   
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
my $year = -1;
my $start = 0;
my $end = 0;
my $found_video = 0;

# where to save tmp files
our $tmp_dir_hash;

# Constant for Page size
#These make measurements easier when using PDF::API2. PDF primarily uses points to measure sizes and distances, so if we define these we can use them later to use other units. For example 5/mm returns 5 millimeters in points. The points (pt) is given just so we can clearly state when we're talking in points.
#Note that these are not necessary, but make it easier to create PDF files in perl. For the technically minded: There are 72 postscript points in an inch and there are 25.4 millimeters in an inch.
use constant DPI => 72;		# PostScript points per inch (standard)
use constant mm => 25.4 / 72; 	# 1 mm in points
use constant in => 1;           # 1 inch in points (72 points)
use constant pt => 1;           # 1 point
use constant DENSITY => "300"; 	# Image DPI for rendering 


# Page Size in mm
use constant A4_x => 210;        # x points in an A4 page ( 595.2755 )
use constant A4_y => 297;        # y points in an A4 page ( 841.8897 )
use constant A5_x => 148;        # x points in an A5 page ( 420 )
use constant A5_y => 210;        # y points in an A5 page ( 595 )
use constant A6_x => 105;        # x points in an A6 page ( 298 )
use constant A6_y => 148;        # y points in an A6 page ( 420 )

# mediabox - the size of our paper in points
# Changed to A5 for booklet printing
my $size_x = A5_x/mm;
my $size_y = A5_y/mm;

# cropbox - the size we'll cut the paper down to at the end
# Improved margins for print (3mm bleed)
my $crop_size = 5/mm;
my $crop_left = $crop_size;
my $crop_bottom = $crop_size;
my $crop_right = $size_x - $crop_size;
my $crop_top = $size_y - $crop_size;

# Draw a Infobox with Background, or just a line
my $ADD_INFOBOX    = "true";

# Infobox size in Percent of Page / 5 %
my $INFOBOX_BOTTOM = $size_y - ($size_y * 0.05);
my $INFOBOX_HEIGHT = $size_y - $INFOBOX_BOTTOM;

# buffer, so resized pic placed well on content part
my $x_buffer = 50;
my $y_buffer = 50;

# Font size - adjusted for A5 format
my $headline_font_size =  80/pt;   # Reduced from 120 for A5
my $date_font_size = 40/pt;        # Reduced from 60
my $from_font_size = 24/pt;        # Reduced from 30
my $text_font_size = "";
my $verbose_font_size = 20/pt;     # Reduced from 30

my $scale = 1;

# some arrays
our @text;
our @images;

our $text_as_line;

# Include some vars from config.pl
my $config_file = glob('~/git/mail2pdf/config.pl') || './config.pl';
my %config = do $config_file or die "Could not load config.pl: $!";

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
            	"year=i" => \$year,
	  ) # flag
or die("Error in command line arguments\n");

if(!$type or $help) {

	print "./mbox2pdf --help\n\n";
	print "--mboxfile=FILE              choose mbox file\n";
	print "--verbose                    enable verbose logging\n";
	print "--debug                      enable debugging\n";
    	print "--type (mbox|imap|s3mount)       choose whether you want to use a local mbox file,a remote imap account or a directory with files per each email\n";
	print "--testlimit=Start(,End)      choose at which position you want to start to generate the pdf file\n";
	print "--year=YEAR		    only print YEAR Content to PDF\n";
	exit;
}

print Dumper \%config if($verbose);

# Some Logging
logging("VERBOSE", "Size: x: '$size_x' y: '$size_y' CropSize: '$crop_size' Infobox Bottom: '$INFOBOX_BOTTOM' Height: '$INFOBOX_HEIGHT' DPI: '".DPI."' scale '$scale'");

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

	## Embed a TTF or use core fonts
	my $courier;
	my $courier_bold;
	if (-e '/Library/Fonts/Courier New.ttf') {
		$courier = $pdf->ttfont('/Library/Fonts/Courier New.ttf');
		$courier_bold = $pdf->ttfont('/Library/Fonts/Courier New Bold.ttf');
	} else {
		$courier = $pdf->corefont('Courier');
		$courier_bold = $pdf->corefont('Courier-Bold');
	}

	# --------------------------------------------------
	# This is the main loop. It's executed once for each email
	# --------------------------------------------------
	while(! $mbox->end_of_file() )
	{

		# last if($email_count > $testlimit);

		logging("VERBOSE", "Start Parsing Email '$email_count'");

		# Fetch Email Content
		my $content = $mbox->read_next_email();

		# if in testlimit mode, check, whether to add this email
		# or not
		my $res = handle_testlimit($email_count, $testlimit, $start, $end);	
		
		# if handle_testlimit skips email, go to next one
		next if ($res == 0);

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

	# Auto-reconnect function
	my $reconnect_imap = sub {
		if (!$imap->IsConnected()) {
			logging("VERBOSE", "IMAP connection lost - reconnecting...");
			$imap = gmail($oauth_token, $username);
			$imap->select($folder) or die "Could not reselect folder: $@\n";
			logging("VERBOSE", "IMAP reconnected successfully");
		}
	};
	
	# --------------------------------------------
	# create a pdf file / pdf object $pdf 
	# --------------------------------------------
	my $pdf = pdf_file("", "create");
	
	## Embed a TTF or use core fonts
	my $courier;
	my $courier_bold;
	if (-e '/Library/Fonts/Courier New.ttf') {
		$courier = $pdf->ttfont('/Library/Fonts/Courier New.ttf');
		$courier_bold = $pdf->ttfont('/Library/Fonts/Courier New Bold.ttf');
	} else {
		$courier = $pdf->corefont('Courier');
		$courier_bold = $pdf->corefont('Courier-Bold');
	}

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

		
		# if in testlimit mode, check, whether to add this email
		# or not
		my $res = handle_testlimit($msg_cnt, $testlimit, $start, $end);	
		
		# if handle_testlimit skips email, go to next one
		next if ($res == 0);

		logging("VERBOSE", "\n++++++++++++++++++++++++++++++++++++++++++++++++++++");	
		logging("VERBOSE", "IMAP Message $msg_cnt from $msgcount");

		# if in year mode, check if email year match
		logging("DEBUG", "Fetch Date Header");
		$reconnect_imap->();
		my $date = $imap->get_header($i, "Date");

		# return 0: ignore | return 1: match
		my $res_hoy = handle_option_year($year, $date);

		if($res_hoy == 0) {

			logging("DEBUG", "handle_option_year: ignore email based on year ($year)");
			next;
		}

		# get message content
		logging("DEBUG", "Fetch message");
		$reconnect_imap->();
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
                pdf_add_email($pdf, $header, $courier, $courier_bold, $msg_cnt);

		undef $parser;
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
	
	## Embed a TTF or use core fonts
	my $courier;
	my $courier_bold;
	if (-e '/Library/Fonts/Courier New.ttf') {
		$courier = $pdf->ttfont('/Library/Fonts/Courier New.ttf');
		$courier_bold = $pdf->ttfont('/Library/Fonts/Courier New Bold.ttf');
	} else {
		$courier = $pdf->corefont('Courier');
		$courier_bold = $pdf->corefont('Courier-Bold');
	}

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
			pdf_add_email($pdf, $header, $courier, $courier_bold, $msg_cnt);

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
	exit;
}

print "File was generated. Have fun\n";
exit;

# --------------------------------------
# Handle year if option for a special
# year is set 
# --------------------------------------
sub handle_option_year {

	my ($year, $date) = @_;

	# no getopts for value year
	return -1 if($year == -1);

	# extract year from email date line (RFC822 format)
	my ($ss,$mm,$hh,$day,$month,$emailyear,$zone) = strptime($date);

	# Have to add offset 1900
	$emailyear = $emailyear + 1900;
	
	if($emailyear && $emailyear != $year ) {

		logging("VERBOSE", "option 'year - $year' is active and this email is from '$emailyear' - skip");
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
	my $nested	= shift || 0;

	my $plain_body 	= "";
	my $html_body 	= "";
	my $content_type;

	$found_video 	= 0;

	# erase global array content
	# only, if not a nested multipart handling
	if($nested == 0) {


		logging("DEBUG", "handle_mime_body: is nested - $nested");
		
		@text	= ();
		@images = ();
		
		$text_as_line = "";
	}

	logging("DEBUG", "handle_mime_body: entity->parts " . $entity->parts);

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

			logging("DEBUG", "handle_mime_body: mime_type " . $ct);
	
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
						
						$text_as_line = $text_as_line . $text . " ";	
						logging("VERBOSE", "Part '$i' - Adding Content Type '$ct' '$text'");					
					}
					else {
						logging("VERBOSE", "skip Mailfooter ..");
						last;
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
	
				$found_video++;
				logging("VERBOSE", "Part $i - Type '$ct'");
			}

			# nested multipart in an subentity
			if( $ct =~"multipart/related" ) {

				handle_mime_body($email_count, $subentity, 1);
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

		logging("VERBOSE", "Remove /tmp/" . $tmp_dir_hash . "/");
		rmtree "/tmp/".$tmp_dir_hash."/" or warn("Could not delete, not empty");

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
	my $courier     = shift;
	my $courier_bold = shift;
	my $email_count = shift;

	# get date headers
	my $date = $header->get('Date');

	# Convert Date
	# the year is the number of years since 1900, and the month is zero-based (0 = January)
	my ($ss,$mm,$hh,$day,$month,$emailyear,$zone) = strptime($date);
	$date = sprintf("%d.%d", $day, $month + 1);
	chomp($date);
	$emailyear = $emailyear + 1900;


	# get more headers and check content if neccessary
	my $subject = $header->get('Subject');

	my $to = $header->get('To');
	chomp($to);

	my $from = $header->get('From');
	chomp($from);

	my ($name, $email) = check_from($from);

	my $contenttype = $header->get("Content-Type");
	chomp($contenttype);
	
	# Logging
	logging("VERBOSE", "'$date' Email from '$from'");


	# Add new Page
	my $page = $pdf->page;

	# printting details
	$page->mediabox( 0,0, $size_x, $size_y);
	$page->cropbox( $crop_left, $crop_bottom, $crop_right, $crop_top );

	# Magazine-Style Layout:
	# Prepare subject for overlay
	my $subject_clean = $subject;
	if($subject_clean) {
		chomp($subject_clean);
		if( $subject_clean =~ /.*(utf-8|utf8|UTF-8|UTF8).*/) {
			my $decoded = decode_mimewords($subject_clean);
			$subject_clean = decode("utf8", $decoded);
			logging("VERBOSE", "Subject encoding is utf8 .. decoded - '$subject_clean'");
		}
	}

	# Magazine-Style: Content-Text nicht anzeigen, nur Bilder mit Overlays
	
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
	my $file = "/tmp/" . $tmp_dir_hash . "/" . md5_hex(rand($ss).$from.$date.$name.rand(50)) . ".jpg";

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
	# y start point depends on text length
	# --------------------------------------------------------
	my $y_value  = calculate_y_value(length($text_as_line), "pic");
	my $geometry = sprintf("%ix%i", $size_x - $x_buffer, $y_value ) ;
	
	# Single Image Email
	if($arrSize == 1) {


		logging("VERBOSE", "Found 1 Picture .. do some magic .. ");

		# Get Image
		$image->Read($images[0]);
		$image->AutoOrient();
		
		$w = $image->Get("width");
		$h = $image->Get("height");

		# Check, if pic size fits content space
		# h: if text is available, Text-Box will be added
		if( $w > $size_x || $h > $y_value ) {

			logging("VERBOSE", "resize PIC cause width w '$w' is greater then size_x '$size_x' ($geometry)" );
			$image->Resize( geometry => $geometry, compress => 'none' );
		}
		elsif($w < 2000 || $h < 2000) {
			
			logging("VERBOSE", "resize PIC cause width is small ($w) then $size_x ($geometry)" );
			$image->Resize( geometry => $geometry, compress => 'none' );
		}


		# Resized values
		$w = $image->Get("width");
		$h = $image->Get("height");

		$image->Set(density => DENSITY);
		$x = $image->Write('jpg:'.$file);
	}
	# Multi Image Email
	elsif ($arrSize > 1) {

		# is calculate in y_value / see above
		my $geo_size_y = $y_value;

		logging("VERBOSE", "size for pic: '$geo_size_y' text_as_line: '$text_as_line'");

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
		$image->Set(density => DENSITY);

		my $montage = $image->Montage(geometry => $geometry , tile => $tile, density => DENSITY, quality => 100, compress => 'none', border => 0, colorspace => 'grey');
		$x = $montage->Write('jpg:'.$file);
		
		# for calculate center position
		$w = $size_x;
		$h = $INFOBOX_BOTTOM - $y_buffer;
	}
	else {

		logging("VERBOSE", "No Images found");
		
		if($found_video > 0 ) {

			# Add Video Note
			my $headline_video = $page->text;
			$headline_video->font( $courier_bold, 60/pt);
			$headline_video->fillcolor('black');
			$headline_video->translate( $size_x * 0.5 , $size_y * 0.5 ) ;
			$headline_video->text_center("Video");
		} 

		return 0;
	}


	# Add photo to pdf page
	my $photo = $page->gfx;

	# check, that file exists
	if (-e $file) {


		logging("VERBOSE", "File exists '$file'");

		my $photo_file = $pdf->image_jpeg($file);

		# ========================================================
		# Intelligente Foto-Skalierung basierend auf Qualität
		# ========================================================

		my $photo_scale;
		my $position_x;
		my $position_y;

		# Prüfe Foto-Auflösung für Qualitätsentscheidung
		my $min_dimension = ($w < $h) ? $w : $h;
		my $max_dimension = ($w > $h) ? $w : $h;

		if($max_dimension >= 1800) {
			# Hohe Qualität: Fullscreen (Cover-Modus)
			logging("VERBOSE", "High quality image ($max_dimension px) - using fullscreen");
			my $scale_x = $size_x / $w;
			my $scale_y = $size_y / $h;
			$photo_scale = ($scale_x > $scale_y) ? $scale_x : $scale_y;

			my $scaled_w = $w * $photo_scale;
			my $scaled_h = $h * $photo_scale;
			$position_x = ($size_x - $scaled_w) / 2;
			$position_y = ($size_y - $scaled_h) / 2;

		} elsif($max_dimension < 1200) {
			# Niedrige Qualität: Max 75% der Seite (zentriert mit Rand)
			logging("VERBOSE", "Lower quality image ($max_dimension px) - limiting scale to 75%");
			my $target_w = $size_x * 0.75;
			my $target_h = $size_y * 0.75;
			my $scale_x = $target_w / $w;
			my $scale_y = $target_h / $h;
			$photo_scale = ($scale_x < $scale_y) ? $scale_x : $scale_y;  # fit mode

			my $scaled_w = $w * $photo_scale;
			my $scaled_h = $h * $photo_scale;
			$position_x = ($size_x - $scaled_w) / 2;
			$position_y = ($size_y - $scaled_h) / 2;

		} else {
			# Mittlere Qualität: 85% der Seite
			logging("VERBOSE", "Medium quality image ($max_dimension px) - using 85% scale");
			my $target_w = $size_x * 0.85;
			my $target_h = $size_y * 0.85;
			my $scale_x = $target_w / $w;
			my $scale_y = $target_h / $h;
			$photo_scale = ($scale_x < $scale_y) ? $scale_x : $scale_y;

			my $scaled_w = $w * $photo_scale;
			my $scaled_h = $h * $photo_scale;
			$position_x = ($size_x - $scaled_w) / 2;
			$position_y = ($size_y - $scaled_h) / 2;
		}

		$photo->image( $photo_file, $position_x, $position_y, $photo_scale);
		logging("VERBOSE", "Write photo - quality: $max_dimension"."px, scale: $photo_scale, pos: $position_x,$position_y");

		# ========================================================
		# Magazine-Style Overlays (Balance: lesbar aber dezent)
		# ========================================================

		# Prüfe ob Email Text hat
		my $has_text = (length($text_as_line) > 0);

		# Top Overlay (45px hoch) - etwas höher für bessere Platzierung
		my $overlay_height_top = 45;
		my $overlay_top = $page->gfx;
		$overlay_top->fillcolor('#222222');
		$overlay_top->rect(0, $size_y - $overlay_height_top, $size_x, $overlay_height_top);
		$overlay_top->fill;

		# Datum - gut lesbar und zentriert, mit Abstand vom oberen Rand
		my $date_formatted = "$day. " . _get_month_name($month + 1);
		my $headline_date = $page->text;
		$headline_date->font($courier_bold, 16/pt);
		$headline_date->fillcolor('white');
		$headline_date->translate($size_x * 0.5, $size_y - 28);
		$headline_date->text_center($date_formatted);

		# Jahr - klein rechts innen, deutlich vom Rand weg
		my $headline_year = $page->text;
		$headline_year->font($courier, 9/pt);
		$headline_year->fillcolor('#AAAAAA');
		$headline_year->translate($size_x * 0.9, $size_y - 22);
		$headline_year->text_right($emailyear);

		# Bottom Overlay - Höhe abhängig von Text
		my $overlay_height_bottom = $has_text ? 90 : 50;
		my $overlay_bottom = $page->gfx;
		$overlay_bottom->fillcolor('#1a1a1a');
		$overlay_bottom->rect(0, 0, $size_x, $overlay_height_bottom);
		$overlay_bottom->fill;

		# Subject - lesbar, mit Abstand vom Rand
		if($subject_clean) {
			my $y_pos = $has_text ? $overlay_height_bottom - 20 : 32;
			my $subject_text = $page->text;
			$subject_text->font($courier_bold, 11/pt);
			$subject_text->fillcolor('white');
			$subject_text->translate($size_x * 0.5, $y_pos);
			$subject_text->text_center($subject_clean);
		}

		# From - sichtbar, mit genug Abstand vom unteren Rand
		if($name) {
			my $y_pos = $has_text ? $overlay_height_bottom - 38 : 16;
			my $from_text = $page->text;
			$from_text->font($courier, 8/pt);
			$from_text->fillcolor('#AAAAAA');
			$from_text->translate($size_x * 0.5, $y_pos);
			$from_text->text_center($name);
		}

		# Text - wenn vorhanden, als Textblock unten
		if($has_text && length($text_as_line) < 200) {
			my $text_display = $page->text;
			$text_display->font($courier, 8/pt);
			$text_display->fillcolor('#CCCCCC');

			# Mehrzeiliger Text (maximal 3 Zeilen)
			my $max_width = $size_x * 0.8;
			my $text_short = substr($text_as_line, 0, 150);
			$text_short .= "..." if length($text_as_line) > 150;

			# Einfache Textausgabe zentriert
			$text_display->translate($size_x * 0.5, 25);
			$text_display->text_center($text_short);
		}

		# Hinweis wenn Text zu lang ist
		if($has_text && length($text_as_line) >= 200) {
			my $hint = $page->text;
			$hint->font($courier, 8/pt);
			$hint->fillcolor('#888888');
			$hint->translate($size_x * 0.5, 15);
			$hint->text_center("[mit Text]");
		}

		# Email count in debug mode (links unten)
		if($verbose || $debug) {
			my $count_text = $page->text;
			$count_text->font($courier, 8/pt);
			$count_text->fillcolor('#666666');
			$count_text->translate(10, 8);
			$count_text->text("#" . $email_count);
		}
	}
	else {

		logging("WARING", "Unable to find image file: $! - add video note");
	}

	# To delete all the images but retain the Image::Magick object use
	@$image = ();

	return 0;
}

# --------------------------------------------------------
# Get month name in German
# --------------------------------------------------------
sub _get_month_name {
	my ($month) = @_;
	my @months = ('', 'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
	              'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember');
	return $months[$month] || $month;
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
	   $text =~ /.*Gesendet von meinem iPhone.*/ ||
	   $text =~ /.*Gesendet mit der GMX-App.*/ ||
	   $text =~/.*HILLER & FRIENDS.*/
	  ) {

		logging("VERBOSE", "ignore some Emailfooter ..");
		return undef;
	}

	# encoding magic / result is 0 or 1
	utf8::decode($text);
	# decode_mimewords($test);	

	return $text;
}

# -----------------------------------------------
# Calculate y_value (for line and new pic size)
# depending on the text length
# -----------------------------------------------
sub calculate_y_value {

	my ($text_length,$type) = @_;

	# Set pic under the line
	my $offset = 0;
	$offset += $y_buffer if($type eq "pic");

	logging("VERBOSE", "calculate_y_value offset '$offset' type '$type'");

	my $y_value = 0;
	if($text_length > 0) {
	
 		if( $text_length > 150) {

			$y_value =  $INFOBOX_BOTTOM - ( $INFOBOX_HEIGHT * 2) - $offset;
			logging("VERBOSE", "Text is over 150 letters. y_value '$y_value'"); 
		}
		else {

	 		$y_value =  $INFOBOX_BOTTOM - $INFOBOX_HEIGHT - $offset;
			logging("VERBOSE", "Text exits. y_value '$y_value'"); 
		}

	}
	else {
		logging("VERBOSE", "No text exits. y_value '$y_value'"); 
		$y_value = $INFOBOX_BOTTOM - $offset;
	}

	return $y_value;
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
# Check and split form Header 
# --------------------------------------------------------
sub check_from {

	my $from = shift;

	if($from =~ /^(.*) <(.+@.+)>$/ ) {

		return $1, $2;
	}

	logging("VERBOSE", "$from .. no match");

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

