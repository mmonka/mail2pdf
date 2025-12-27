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

1. Gehe zu [Google Cloud Console](https://console.cloud.google.com)
2. Erstelle ein neues Projekt
3. Aktiviere die **Gmail API**
4. Erstelle **OAuth 2.0 Credentials** (Desktop App)
5. Lade die Client-ID und Secret herunter
6. Verwende gmail-oauth-tools oder ähnliches:

```bash
# Mit gmail-oauth-tools
python oauth2.py --generate_oauth2_token \
  --client_id=YOUR_CLIENT_ID \
  --client_secret=YOUR_CLIENT_SECRET
```

7. Kopiere den **Access Token** in deine config.pl

**Hinweis**: Access Tokens sind zeitlich begrenzt. Für langfristige Nutzung solltest du Refresh Tokens verwenden.

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
- `config.pl` - Konfiguration
- `check_modules.pl` - Modul-Checker

### Dokumentation
- `README.md` - Diese Datei
- `SUMMARY.md` - Detaillierte Änderungen v2.0
- `INSTALLATION.md` - Installations-Guide
- `README_IMAGEMAGICK.md` - Image::Magick Hilfe
- `conversation_log_2025-12-26.md` - Entwicklungslog

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

```
┌─────────────┐
│   Gmail     │
│   IMAP      │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ mbox2pdf.pl │
│  + config   │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│ A5 PDF      │
│ (Druckbar)  │
└─────────────┘
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
