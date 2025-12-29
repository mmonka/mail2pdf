#!/usr/bin/perl
# Erneuert den Access Token mit dem Refresh Token

use strict;
use warnings;
use lib "$ENV{HOME}/perl5/lib/perl5";
use LWP::UserAgent;
use JSON::PP;

# Lade Config
my %config = do './config.pl';
my $client_id = $config{client_id} or die("Missing client_id in config.pl");
my $client_secret = $config{client_secret} or die("Missing client_secret in config.pl");

# Refresh Token aus Environment Variable oder config.pl Kommentar
my $refresh_token = $ENV{GMAIL_REFRESH_TOKEN};

if (!$refresh_token) {
    # Versuche refresh_token aus config.pl Kommentar zu lesen
    open(my $fh, '<', 'config.pl') or die "Cannot read config.pl: $!";
    my @lines = <$fh>;
    close($fh);

    foreach my $line (@lines) {
        if ($line =~ /# Refresh Token.*:\s*\n/ || $line =~ /^# (1\/\/.+)$/) {
            chomp($refresh_token = $1 || '');
            $refresh_token =~ s/^#\s*//;
            last if $refresh_token;
        }
    }

    die "No refresh token found. Set GMAIL_REFRESH_TOKEN environment variable or add it as comment in config.pl\n" unless $refresh_token;
}

print "Erneuere Access Token mit Refresh Token...\n";

my $ua = LWP::UserAgent->new();
my $response = $ua->post(
    "https://oauth2.googleapis.com/token",
    Content => {
        refresh_token => $refresh_token,
        client_id => $client_id,
        client_secret => $client_secret,
        grant_type => "refresh_token"
    }
);

if (!$response->is_success) {
    print "FEHLER: " . $response->status_line . "\n";
    print $response->content . "\n";
    exit 1;
}

my $json = decode_json($response->content);

print "\n✅ Neuer Access Token generiert!\n\n";

my $access_token = $json->{access_token};
my $expires_in = $json->{expires_in};

print "Access Token: " . substr($access_token, 0, 60) . "...\n";
print "Gültig für: $expires_in Sekunden (" . int($expires_in/3600) . " Stunden)\n\n";

# config.pl aktualisieren
my $config_content = <<"EOF";
# Configuration for mbox2pdf.pl
# Generated: @{[scalar localtime]}

return (
    username    => '$config{username}',
    oauth_token => '$access_token',
    client_id   => '$client_id',
    client_secret => '$client_secret',
    path        => '$config{path}',
    filename    => '$config{filename}',
    s3mount     => '$config{s3mount}'
);

# Refresh Token (für Token-Erneuerung):
# $refresh_token
EOF

open(my $fh, '>', 'config.pl') or die "Kann config.pl nicht schreiben: $!";
print $fh $config_content;
close($fh);

print "✅ config.pl wurde aktualisiert!\n\n";
print "Du kannst jetzt das Script ausführen:\n";
print "  perl mbox2pdf.pl --type imap --testlimit 1,3 --verbose\n\n";
