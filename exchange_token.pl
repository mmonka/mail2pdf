#!/usr/bin/perl
# Tauscht Authorization Code gegen Access Token

use strict;
use warnings;
use lib "$ENV{HOME}/perl5/lib/perl5";
use LWP::UserAgent;
use JSON::PP;

# Lade Config falls vorhanden
my %config;
if (-e 'config.pl') {
    %config = do './config.pl';
}

my $client_id = $config{client_id} || $ENV{GMAIL_CLIENT_ID} || die("Missing client_id. Set in config.pl or GMAIL_CLIENT_ID env var\n");
my $client_secret = $config{client_secret} || $ENV{GMAIL_CLIENT_SECRET} || die("Missing client_secret. Set in config.pl or GMAIL_CLIENT_SECRET env var\n");
my $username = $config{username} || $ENV{GMAIL_USERNAME} || die("Missing username. Set in config.pl or GMAIL_USERNAME env var\n");
my $redirect_uri = "http://localhost";

die "Usage: $0 <authorization_code>\n" unless @ARGV;

my $auth_code = $ARGV[0];

# Extrahiere Code aus URL falls ganze URL übergeben wurde
if ($auth_code =~ /code=([^&]+)/) {
    $auth_code = $1;
}

print "Tausche Authorization Code gegen Access Token...\n";

my $ua = LWP::UserAgent->new();
my $response = $ua->post(
    "https://oauth2.googleapis.com/token",
    Content => {
        code => $auth_code,
        client_id => $client_id,
        client_secret => $client_secret,
        redirect_uri => $redirect_uri,
        grant_type => "authorization_code"
    }
);

if (!$response->is_success) {
    print "FEHLER: " . $response->status_line . "\n";
    print $response->content . "\n";
    exit 1;
}

my $json = decode_json($response->content);

print "\n✅ Token erfolgreich generiert!\n\n";

my $access_token = $json->{access_token};
my $refresh_token = $json->{refresh_token} || "";
my $expires_in = $json->{expires_in};

print "Access Token: " . substr($access_token, 0, 60) . "...\n";
print "Gültig für: $expires_in Sekunden (" . int($expires_in/3600) . " Stunden)\n\n";

if ($refresh_token) {
    print "Refresh Token: " . substr($refresh_token, 0, 60) . "...\n\n";
}

# config.pl aktualisieren
my $config_content = <<"EOF";
# Configuration for mbox2pdf.pl
# Generated: @{[scalar localtime]}

return (
    username    => '$username',
    oauth_token => '$access_token',
    client_id   => '$client_id',
    client_secret => '$client_secret',
    path        => '$config{path}' || '/tmp/',
    filename    => '$config{filename}' || 'gmail-export.pdf',
    s3mount     => '$config{s3mount}' || '/tmp/s3mount/'
);

# Refresh Token (für Token-Erneuerung):
# $refresh_token
EOF

open(my $fh, '>', 'config.pl') or die "Kann config.pl nicht schreiben: $!";
print $fh $config_content;
close($fh);

print "✅ config.pl wurde aktualisiert!\n\n";
print "Du kannst jetzt testen mit:\n";
print "  perl mbox2pdf.pl --type imap --testlimit 1,3 --verbose\n\n";
