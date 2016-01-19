Idea is to have a diary for kids or whatever

Download gmail mailbox via google takeout and convert mbox formated emails to pdfs
or connect directly to gmail via imaps/oauth2.

Help:

./mbox2pdf --options

--mboxfile=FILE              choose mbox file<br>
--verbose                    enable verbose logging<br>
--debug                      enable debugging<br>
--type mbox|imap             choose whether you want to use a local mbox file or a remote imap account<br>
--testlimit=Start(,End)      choose at which position you want to start to generate the pdf file<br>

You need a config.pl file in your execute dir:

# --------------------------------------------------
# This is my config file

mboxfile        => "mbox file",<br>
filename        => "your filename",<br>
path            => "your path",<br>
oauth_token     => "yourtoken",<br>
username        => '.......@gmail.com'<br>
# -------------------------------------------------

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
