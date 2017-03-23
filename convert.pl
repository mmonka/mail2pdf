#!/usr/bin/perl
# Command Line Arguments::
# 0 = path to original pdf

# include modules
use PDF::API2;

use constant DPI => 72;
use constant mm => 25.4 / DPI;  # 25.4 mm in an inch, 72 points in an inch
use constant in => 1 / DPI;     # 72 points in an inch
use constant pt => 1;           # 1 point
use constant DENSITY => "300";          # DPI

# load pdf from passed argument
my $pdf = PDF::API2->open($ARGV[0]) || die("Unable to open PDF");
# new pdf to hold legal size
my $pdf_out = PDF::API2->new;

# resize new pdf page to legal
# $pdf_out->cropbox(7,7,560,807);
$pdf_out->mediabox(154/mm, 216/mm);
$pdf_out->cropbox('A5');
# $pdf_out->mediabox(595,842);

# get total number of pages
my $pagenumber = $pdf->pages;

for ($count=1; $count<=$pagenumber; $count++)
{
    # get the current page/new page
    my $page = $pdf->openpage($count);
    my $page_out = $pdf_out->page(0);


    # turn old pdf into graphic
    # import into new pdf at offset
    my $gfx = $page_out->gfx;
    my $xo = $pdf_out->importPageIntoForm($pdf, $count);
    $gfx->formimage($xo,
		    0, 0, # x y
		    0.085 );   # scale    


}


# save and close
print Dumper $pdf_out;

$pdf_out->saveas("/Users/mmonka/Desktop/mini.pdf");
$pdf_out->end();
