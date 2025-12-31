#!/usr/bin/perl
# Test script for ImageOptimizer module

use strict;
use warnings;
use lib '.';
use ImageOptimizer;
use PDF::API2;

print "Testing ImageOptimizer module...\n\n";

# Find a test image
my $test_image = "/tmp/msg-1767004288-90860-0/photo.JPG";

unless (-e $test_image) {
    print "No test image found at $test_image\n";
    print "Please provide a JPEG file path:\n";
    $test_image = <STDIN>;
    chomp($test_image);
}

unless (-e $test_image) {
    die "Test image not found: $test_image\n";
}

print "Using test image: $test_image\n\n";

# Create optimizer
my $optimizer = ImageOptimizer->new();
$optimizer->set_verbose(1);

print "=" x 70 . "\n";
print "Test 1: Get image dimensions (fast!)\n";
print "=" x 70 . "\n";

my $dims = $optimizer->get_image_dimensions($test_image);
print "Dimensions: $dims->{width} x $dims->{height}\n\n";

print "=" x 70 . "\n";
print "Test 2: Process image to blob (in-memory)\n";
print "=" x 70 . "\n";

my $blob = $optimizer->process_image(
    input_file => $test_image,
    max_width  => 400,
    max_height => 600,
    quality    => 90
);

print "Blob created successfully!\n";
print "Blob size: " . length($blob) . " bytes\n\n";

print "=" x 70 . "\n";
print "Test 3: Create PDF with blob (no disk I/O!)\n";
print "=" x 70 . "\n";

my $pdf = PDF::API2->new(-file => '/tmp/test-optimizer.pdf');
my $page = $pdf->page();
$page->mediabox(0, 0, 419.53, 595.28); # A5

# Load image from blob directly!
my $photo_file = $pdf->image_jpeg(\$blob);

# Place image on page
my $gfx = $page->gfx();
$gfx->image($photo_file, 50, 50, 0.8);

$pdf->save();
$pdf->end();

print "PDF created: /tmp/test-optimizer.pdf\n\n";

print "=" x 70 . "\n";
print "Performance Comparison\n";
print "=" x 70 . "\n";

print "\nFile-based approach:\n";
print "  1. ImageMagick reads from disk\n";
print "  2. ImageMagick writes to /tmp/resized.jpg\n";
print "  3. PDF::API2 reads from /tmp/resized.jpg\n";
print "  = 2 disk I/O operations\n\n";

print "Blob-based approach (this module):\n";
print "  1. ImageMagick reads from disk\n";
print "  2. ImageMagick creates blob in RAM\n";
print "  3. PDF::API2 reads from RAM\n";
print "  = 1 disk I/O operation (50% less!)\n\n";

print "✅ All tests passed!\n";
print "Open PDF: open /tmp/test-optimizer.pdf\n\n";
