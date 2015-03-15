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
use Getopt::Long;

# Image Manipulatin
use Image::Magick;
   
# --------------------------------------------------
# Global Variables
# --------------------------------------------------
my $mboxfile;
my $verbose;
my $debug;

our @text;
our @images;

# --------------------------------------------------
# Getopt definition
# --------------------------------------------------
GetOptions(	"mboxfile=s" => \$mboxfile, # string
    		"verbose" => \$verbose,
    		"debug" => \$debug
	  ) # flag
or die("Error in command line arguments\n");

 
MIME::Tools->debugging(1) if($debug);
MIME::Tools->quiet(0) if($verbose);

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

    	### Tell it where to put things:
    	$parser->output_under("/tmp");

	my $entity = $parser->parse_data($content);
	my $header = $entity->head;

	# Sanity checks
	next if ($header->get('From') =~ /facebook/);

	my $error = ($@ || $parser->last_error);
	
	handle_mime_body($email_count,$entity);
	pdf_add_email($header);

	$email_count++;	
	# last if($email_count == 26);
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
				$image->set(debug=>10);
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
	
	my $task = shift;
	my $filename = "/Users/markus/Desktop/feline_tagebuch.pdf";

	# ---------------------------------------------------
	# Create PDF object
	# ---------------------------------------------------
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

	# get email headers
	my $subject = $header->get('Subject');
	my $to = $header->get('To');
	my $from = $header->get('From');
	my $date = $header->get('Date');
	my $contenttype = $header->get("Content-Type");

	# delete newlines
	chomp($subject);
	chomp($to);
	chomp($from);
	chomp($date);
	chomp($contenttype);

	logging("VERBOSE", "'$date' Email from '$from'");

	# decode subject 
	if($subject =~ /.*(utf-8|utf8).*/) {

		logging("DEBUG", "Subject encoding is utf8");
		my $decoded = decode_mimewords($subject);

		# Fix encoding
		$subject = $decoded;

	}

	# 72 DPI -> 595 x 842
	my $a4 = $pdf->new_page('MediaBox' => $pdf->get_page_size('A4'));

	# Add a page which inherits its attributes from $a4
  	my $page = $a4->new_page;
 
	# Prepare a font
  	my $f1 = $pdf->font('BaseFont' => 'Helvetica');
	
	# Mail Header Information 
  	$page->stringc($f1, 12, 150, 696, "von $from");
  	$page->stringc($f1, 12, 150, 722, "Datum $date");
  	$page->stringc($f1, 12, 150, 753, "Subject '$subject'");

	my $content = "";

	# Get Text-Element and add to PDF
	foreach(@text) {

		next if($_ eq "delete");
		logging("VERBOSE", "Text: $_");	
		$content = $content . $_ . "\r\n";
	}

  	$page->stringc($f1, 20, 150, 650, "Text: " . $content);

	# --------------------------------------------------------
	# TODO: check orientation of image
	#       -> AUTO ROTATION
	# --------------------------------------------------------
	my $image = Image::Magick->new(magick=>'JPEG');
	$image->set(debug=>'all') if($debug);
	$image->set(verbose=>'true') if($verbose);
	
	# --------------------------------------------------------
	# Set Pics to PDF	
	# --------------------------------------------------------
	my $arrSize = @images;
	my $file = "/tmp/123456789.jpg";
	my $x;

	# Image Size
	my $w;
	my $h;

	# Image Position
	my $xpos = 0;
	my $ypos = 0;
	
	# Single Image Email
	if($arrSize == 1) {
			
		$image->Read($images[0]);
		$image->AutoOrient();
		$image->Resize( geometry => '500x600' );
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

		# Image Montage
		logging("VERBOSE", "!!!!!Multi Image Email -> Montage");
		my $montage = $image->Montage(background => "white", borderwidth => "5", geometry => "100x100");
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
