Idea is to have a diary for kids or whatever

Download gmail mailbox via google takeout and convert mbox formated emails to pdfs

Help:

./mbox2pdf --options

--mboxfile=FILE              choose mbox file
--verbose                    enable verbose logging
--debug                      enable debugging
--type mbox|imap             choose whether you want to use a local mbox file or a remote imap account
--testlimit=Start(,End)      choose at which position you want to start to generate the pdf file


Libs:

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
