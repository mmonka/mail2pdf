# mbox2pdf - Email to A5 Booklet Converter

Ein Tagebuch aus Gmail-Emails erstellen! Ideal für Kinder-Tagebücher oder persönliche Jahrbücher.

Konvertiert Gmail-Emails mit Bildern in ein druckbares **A5-PDF-Büchlein**.

## ✨ Version 2.0 (2025-12-26) - Neu!

- ✅ **A5-Format** - Optimiert für Büchlein-Druck (148 x 210 mm)
- ✅ **Korrekte DPI** - 72 PostScript Points für echten Druck
- ✅ **Aktivierte CropBox** - Professionelle Druckränder (5mm)
- ✅ **Angepasste Schriftgrößen** - Perfekt für A5
- ✅ **Verbessertes Layout** - Einheitlich und schön
- ✅ **Alle Module installiert** - Inkl. Image::Magick ✅

Basiert auf PDF::API2 und ImageMagick.

**Lizenz**: GPLv2

## 🚀 Schnellstart

### 1. Test-PDF generieren (ohne Gmail)
```bash
perl test_pdf.pl
open /tmp/test-a5-booklet.pdf
```

### 2. Konfiguration für Gmail
```bash
cp config.pl.example config.pl
# Bearbeite config.pl mit deinen Credentials
```

### 3. Emails von Gmail holen
```bash
perl mbox2pdf.pl --type imap --verbose
```

## 📋 Kommandozeilen-Optionen

```bash
perl mbox2pdf.pl [OPTIONS]

--type TYPE              Quelle: mbox|imap|s3mount
--mboxfile FILE          Lokale mbox-Datei
--verbose                Ausführliche Ausgabe
--debug                  Debug-Modus
--testlimit Start,End    Nur bestimmte Emails (z.B. 1,10)
--year YEAR              Nur Emails aus diesem Jahr
--path PATH              Ausgabepfad (überschreibt config.pl)
--filename NAME          Dateiname (überschreibt config.pl)
```

### Beispiele
```bash
# Alle Emails von Gmail
perl mbox2pdf.pl --type imap --verbose

# Nur 2025 Emails
perl mbox2pdf.pl --type imap --year 2025 --verbose

# Lokale mbox-Datei
perl mbox2pdf.pl --type mbox --mboxfile emails.mbox

# Test: Nur Emails 1-10
perl mbox2pdf.pl --type imap --testlimit 1,10
```

## ⚙️ Konfiguration (config.pl)

Die config.pl Datei muss im gleichen Verzeichnis liegen:

```perl
# config.pl
return (
    username    => 'deine@gmail.com',
    oauth_token => 'dein_oauth_access_token',
    path        => '/Users/deinname/output/',
    filename    => 'meine-emails.pdf',
    s3mount     => '/mnt/s3/'  # optional
);
```

**Wichtig**: Die Datei muss mit `return (` beginnen und mit `);` enden!

## 🔑 Gmail OAuth Token erstellen

### Schritt 1: Google Cloud Projekt einrichten

1. Gehe zu [Google Cloud Console](https://console.cloud.google.com)
2. Erstelle ein neues Projekt
3. Aktiviere die **Gmail API**
4. Erstelle **OAuth 2.0 Credentials** (Desktop App / Other)
5. Notiere dir:
   - Client-ID
   - Client-Secret

### Schritt 2: Authorization Code holen

1. Erstelle die OAuth-URL (ersetze `YOUR_CLIENT_ID`):

```
https://accounts.google.com/o/oauth2/v2/auth?client_id=YOUR_CLIENT_ID&redirect_uri=http://localhost&response_type=code&scope=https://mail.google.com/&access_type=offline
```

2. Öffne die URL im Browser
3. Melde dich mit deinem Gmail-Account an
4. Erlaube den Zugriff
5. Kopiere den **Authorization Code** aus der Redirect-URL:
   ```
   http://localhost/?code=4/0ATX87lM...&scope=...
   ```

### Schritt 3: Token generieren mit `exchange_token.pl`

Dieses Script tauscht den Authorization Code gegen Access Token und Refresh Token:

```bash
# Erst config.pl mit Client-ID und Secret erstellen
cp config.pl.example config.pl
# Bearbeite config.pl und füge client_id und client_secret ein

# Dann Authorization Code gegen Tokens tauschen
perl exchange_token.pl "http://localhost/?code=4/0ATX87lM..."
# Oder nur den Code:
perl exchange_token.pl "4/0ATX87lM..."
```

**Was macht das Script?**
- Liest Client-ID und Secret aus `config.pl`
- Sendet Authorization Code an Google OAuth API
- Empfängt Access Token (gültig 1h) und Refresh Token (unbegrenzt)
- Aktualisiert `config.pl` automatisch mit beiden Tokens
- Speichert Refresh Token als Kommentar in `config.pl`

**Ausgabe:**
```
✅ Token erfolgreich generiert!

Access Token: ya29.a0Aa7pCA...
Gültig für: 3599 Sekunden (0 Stunden)

Refresh Token: 1//03JvVXYLO...

✅ config.pl wurde aktualisiert!
```

### Schritt 4: Token erneuern mit `refresh_token.pl`

Access Tokens laufen nach 1 Stunde ab. Mit dem Refresh Token kannst du neue Access Tokens generieren:

```bash
perl refresh_token.pl
```

**Was macht das Script?**
- Liest Client-ID, Client-Secret und Refresh Token aus `config.pl`
- Sendet Refresh Token an Google OAuth API
- Empfängt neuen Access Token (gültig 1h)
- Aktualisiert `config.pl` automatisch

**Ausgabe:**
```
Erneuere Access Token mit Refresh Token...

✅ Neuer Access Token generiert!

Access Token: ya29.a0Aa7pCA...
Gültig für: 3599 Sekunden (0 Stunden)

✅ config.pl wurde aktualisiert!
```

**Hinweis**: Führe dieses Script vor jedem längeren Email-Export aus, damit der Token nicht während des Exports abläuft!

### Alternative: Umgebungsvariablen

Statt Secrets in `config.pl` kannst du auch Umgebungsvariablen nutzen:

```bash
export GMAIL_CLIENT_ID="your-client-id.apps.googleusercontent.com"
export GMAIL_CLIENT_SECRET="your-client-secret"
export GMAIL_USERNAME="deine@gmail.com"
export GMAIL_REFRESH_TOKEN="1//03JvVXYLO..."

perl exchange_token.pl "4/0ATX87lM..."
perl refresh_token.pl
```

### Token-Sicherheit ⚠️

- **Niemals** Client-Secret, Access Token oder Refresh Token öffentlich teilen!
- `config.pl` ist in `.gitignore` und wird NICHT committed
- Verwende `config.pl.example` als Template (ohne echte Tokens)
- Bei Kompromittierung: Token in Google Cloud Console widerrufen

## 📦 Perl-Module (Alle installiert ✅)

Alle benötigten Module sind installiert und funktionieren:

### Mail & MIME
- Mail::IMAPClient ✅
- Mail::Mbox::MessageParser ✅
- MIME::Parser ✅
- MIME::Words ✅
- MIME::Body ✅
- MIME::Base64 ✅

### PDF
- PDF::API2 ✅
- PDF::TextBlock ✅

### Bilder
- Image::Magick ✅ (manuell installiert)

### Sonstige
- Date::Parse ✅
- Getopt::Long ✅
- File::Path ✅
- Digest::MD5 ✅
- URI::Escape ✅
- Encode ✅
- Data::Dumper ✅

Prüfen mit:
```bash
perl check_modules.pl
```

## 📐 Technische Details

### PDF-Spezifikationen
- **Format**: A5 (148 x 210 mm)
- **Points**: 419.53 x 595.28 pt
- **DPI**: 72 PostScript Points
- **Bild-DPI**: 300
- **CropBox**: Aktiviert mit 5mm Margins
- **PDF-Version**: 1.4

### Layout
| Element | Größe | Position |
|---------|-------|----------|
| Infobox | 5% Höhe | Top, orange |
| Datum | 40pt | Links oben |
| Jahr | 40pt | Rechts oben |
| Subject | 24pt | Unter Infobox, 70% Breite |
| Content | 20pt | Unter Subject, 80% Breite |
| Bilder | Auto-skaliert | Zentriert |

### Schriftarten
- Standard: Courier (oder Courier New.ttf)
- Bold: Courier-Bold (oder Courier New Bold.ttf)

## 🖨️ Druckempfehlungen

Das PDF ist optimiert für:
- **A5 Büchlein-Druck** (148 x 210 mm)
- **Duplex-Druck** (beidseitig, lange Kante)
- **Professionelle Druckereien** (mit Beschnittzugabe)

### Druckeinstellungen
1. Papierformat: A5
2. Duplex: Lange Kante (für Bindung)
3. Skalierung: Keine (100%)
4. Farbmodus: Farbe
5. Qualität: Hoch

## 📁 Projektdateien

### Hauptdateien
- `mbox2pdf.pl` - Haupt-Script ⭐
- `test_pdf.pl` - Test-PDF Generator
- `check_modules.pl` - Modul-Checker

### OAuth Token Management
- `exchange_token.pl` - Tauscht Authorization Code gegen Tokens
- `refresh_token.pl` - Erneuert Access Token mit Refresh Token
- `config.pl.example` - Template für Konfiguration
- `config.pl` - Konfiguration (nicht im Git, enthält Secrets)

### Dokumentation
- `README.md` - Diese Datei
- `SUMMARY.md` - Detaillierte Änderungen v2.0
- `INSTALLATION.md` - Installations-Guide
- `README_IMAGEMAGICK.md` - Image::Magick Hilfe
- `conversation_log_2025-12-26.md` - Entwicklungslog

### Git
- `.gitignore` - Schützt Secrets vor versehentlichem Commit

## 📊 Changelog v2.0 (2025-12-26)

| Was | Vorher | Nachher |
|-----|--------|---------|
| Format | A4 | **A5** |
| DPI | 300 | **72** |
| CropBox | ❌ | **✅** |
| Margins | 3mm | **5mm** |
| Headline | 120pt | **80pt** |
| Subject | 35pt | **24pt** |
| Content | 30pt | **20pt** |
| Text Align | Justify | **Left** |

## 🎯 Workflow

### Erster Setup (einmalig)

```
┌────────────────────┐
│ Google Cloud       │
│ OAuth Setup        │
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│ Authorization Code │
│ (im Browser holen) │
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│ exchange_token.pl  │
│ → Access Token     │
│ → Refresh Token    │
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│ config.pl          │
│ (automatisch       │
│  aktualisiert)     │
└────────────────────┘
```

### Regulärer Email-Export

```
┌────────────────────┐
│ refresh_token.pl   │ ← Vor jedem Export
│ (Token erneuern)   │   (wenn Token abgelaufen)
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│ Gmail IMAP         │
│ (mit frischem      │
│  Access Token)     │
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│ mbox2pdf.pl        │
│ --type imap        │
│ --verbose          │
└─────────┬──────────┘
          │
          ▼
┌────────────────────┐
│ A5 PDF             │
│ (druckfertig)      │
└────────────────────┘
```

### Typischer Export-Befehl

```bash
# Token erneuern (falls älter als 1h)
perl refresh_token.pl

# Emails exportieren
perl mbox2pdf.pl --type imap --testlimit 1,50 --verbose
```

## 🔗 Links

- [PDF::API2 Examples](http://rick.measham.id.au/pdf-api2/)
- [Gmail API OAuth](https://developers.google.com/gmail/api/auth/web-server)
- [ImageMagick](https://imagemagick.org/)

## ✅ Status

- [x] A5-Format implementiert
- [x] DPI korrigiert
- [x] Druckeinstellungen optimiert
- [x] Layout verbessert
- [x] Alle Module installiert
- [x] Test-PDF erfolgreich
- [ ] Mit echten Gmail-Emails testen (benötigt OAuth Token)

---

**Version**: 2.0 (2025-12-26)
**Status**: Produktionsbereit ✅
**Lizenz**: GPLv2
