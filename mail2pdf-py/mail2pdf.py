#!/usr/bin/env python3
"""
mail2pdf - Convert Gmail emails with images to beautiful PDF booklets

Usage:
    python mail2pdf.py --verbose
    python mail2pdf.py --theme magazine --year 2025
    python mail2pdf.py --limit 50 --output /tmp/album.pdf
"""

import sys
import os
import subprocess
import shutil
from pathlib import Path
from typing import Optional, Dict, Any, List
from concurrent.futures import ProcessPoolExecutor, as_completed
import multiprocessing

import click
import yaml
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn, BarColumn, TaskProgressColumn
from rich.panel import Panel
from rich.table import Table

# Add lib to path
sys.path.insert(0, str(Path(__file__).parent))

from lib.gmail import GmailClient
from lib.image_processor import ImageProcessor
from lib.pdf_generator import PDFGenerator

# Rich console for pretty output
console = Console()

# Project paths
PROJECT_DIR = Path(__file__).parent
THEMES_DIR = PROJECT_DIR / 'themes'
TEMPLATES_DIR = PROJECT_DIR / 'templates'


def convert_to_cmyk(input_path: str, output_path: str = None) -> bool:
    """
    Convert RGB PDF to CMYK using Ghostscript.
    Required for professional printing (drucksofa.de etc.)

    Args:
        input_path: Path to RGB PDF
        output_path: Path for CMYK PDF (default: replaces input)

    Returns:
        True if successful
    """
    # Check if Ghostscript is available
    gs_cmd = None
    for cmd in ['gs', 'gswin64c', 'gswin32c']:
        if shutil.which(cmd):
            gs_cmd = cmd
            break

    if not gs_cmd:
        print("[yellow]Warning: Ghostscript not found. PDF remains in RGB.[/yellow]")
        print("[yellow]Install with: brew install ghostscript[/yellow]")
        return False

    if output_path is None:
        output_path = input_path

    # Create temp output
    temp_output = input_path + '.cmyk.tmp.pdf'

    try:
        # Ghostscript command for CMYK conversion
        # Uses FOGRA39 (ISO Coated v2) - standard for European printing
        cmd = [
            gs_cmd,
            '-dSAFER',
            '-dBATCH',
            '-dNOPAUSE',
            '-dNOCACHE',
            '-sDEVICE=pdfwrite',
            '-r300',  # Explicit 300 DPI for print quality
            '-sColorConversionStrategy=CMYK',
            '-dProcessColorModel=/DeviceCMYK',
            '-dCompatibilityLevel=1.4',
            '-dAutoRotatePages=/None',
            '-dPDFSETTINGS=/prepress',  # High quality for print
            f'-sOutputFile={temp_output}',
            input_path
        ]

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300  # 5 min timeout
        )

        if result.returncode != 0:
            print(f"[red]Ghostscript error: {result.stderr}[/red]")
            return False

        # Replace original with CMYK version
        os.replace(temp_output, output_path)
        return True

    except subprocess.TimeoutExpired:
        print("[red]CMYK conversion timed out[/red]")
        return False
    except Exception as e:
        print(f"[red]CMYK conversion failed: {e}[/red]")
        return False
    finally:
        # Cleanup temp file if it exists
        if os.path.exists(temp_output):
            os.remove(temp_output)


def process_single_email(args: tuple) -> Optional[Dict[str, Any]]:
    """
    Process a single email in a worker process.
    Must be top-level function for ProcessPoolExecutor.

    Args:
        args: Tuple of (email_data, theme_config, email_index)

    Returns:
        Page dict ready for PDF generation, or None on error
    """
    email_data, theme_config, email_index = args

    try:
        # Each worker creates its own ImageProcessor (process-safe)
        from lib.image_processor import ImageProcessor
        processor = ImageProcessor(theme_config, verbose=False)

        try:
            # Process images
            processed_images = processor.process_email_images(email_data.get('images', []))

            # Handle multiple images (create grid if > 1)
            if len(processed_images) > 1:
                grid_path = processor.create_grid(processed_images, len(processed_images))
                if grid_path:
                    processed_images = [{'path': grid_path, 'index': 0}]

            # Get rotation for polaroid effect
            rotation = processor.get_rotation()

            # Create page data
            page = {
                'date': email_data.get('date'),
                'subject': email_data.get('subject', ''),
                'sender_name': email_data.get('sender_name', ''),
                'sender_email': email_data.get('sender_email', ''),
                'text': email_data.get('text', ''),
                'images': processed_images,
                'rotation': rotation,
                '_index': email_index  # Keep original order
            }

            # Don't cleanup - we need the temp files for PDF generation
            # Cleanup will happen after PDF is created
            return page

        except Exception as e:
            processor.cleanup()
            raise e

    except Exception as e:
        print(f"[Worker] Error processing email {email_index}: {e}")
        return None


def load_config(config_path: Optional[str] = None) -> Dict[str, Any]:
    """Load configuration from YAML file"""
    if config_path:
        path = Path(config_path)
    else:
        path = PROJECT_DIR / 'config.yaml'

    if not path.exists():
        console.print(f"[red]ERROR:[/red] Config file not found: {path}")
        console.print(f"[yellow]Hint:[/yellow] Copy config.yaml.example to config.yaml and fill in your credentials")
        sys.exit(1)

    with open(path, 'r', encoding='utf-8') as f:
        return yaml.safe_load(f)


def load_theme(theme_name: str) -> Dict[str, Any]:
    """Load theme configuration"""
    theme_path = THEMES_DIR / f'{theme_name}.yaml'

    if not theme_path.exists():
        available = [f.stem for f in THEMES_DIR.glob('*.yaml')]
        console.print(f"[red]ERROR:[/red] Theme '{theme_name}' not found")
        console.print(f"[yellow]Available themes:[/yellow] {', '.join(available)}")
        sys.exit(1)

    with open(theme_path, 'r', encoding='utf-8') as f:
        theme = yaml.safe_load(f)

    # Add defaults for optional settings
    theme.setdefault('overlays', {'top': {'enabled': False}, 'bottom': {'enabled': False}})
    theme.setdefault('decorations', {'tape': {'enabled': False}, 'date_stamp': {}})
    theme.setdefault('grid', {'gap': '4mm', 'layouts': {}})

    return theme


def save_config(config: Dict[str, Any], config_path: Optional[str] = None):
    """Save updated config (e.g., new tokens)"""
    if config_path:
        path = Path(config_path)
    else:
        path = PROJECT_DIR / 'config.yaml'

    with open(path, 'w', encoding='utf-8') as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True)


@click.command()
@click.option('--config', '-c', type=click.Path(), help='Path to config.yaml')
@click.option('--theme', '-t', default=None, help='Theme name (polaroid, magazine, minimal)')
@click.option('--output', '-o', type=click.Path(), help='Output PDF path')
@click.option('--year', '-y', type=int, help='Filter emails by year')
@click.option('--limit', '-l', type=int, help='Maximum number of emails to process')
@click.option('--start', '-s', type=int, default=0, help='Start index for pagination')
@click.option('--folder', '-f', default='INBOX', help='IMAP folder (default: INBOX)')
@click.option('--verbose', '-v', is_flag=True, help='Verbose output')
@click.option('--debug', is_flag=True, help='Debug mode (save intermediate HTML)')
@click.option('--refresh-token', is_flag=True, help='Only refresh OAuth token and exit')
@click.option('--test', is_flag=True, help='Test mode: generate PDF with sample data')
@click.option('--cmyk/--no-cmyk', default=True, help='Convert to CMYK for professional printing (default: yes)')
@click.option('--cover', type=click.Path(exists=True), help='Cover image path')
@click.option('--cover-title', default='Feline', help='Title on cover page (default: Feline)')
@click.option('--cover-subtitle', default=None, help='Subtitle on cover page')
def main(
    config: Optional[str],
    theme: Optional[str],
    output: Optional[str],
    year: Optional[int],
    limit: Optional[int],
    start: int,
    folder: str,
    verbose: bool,
    debug: bool,
    refresh_token: bool,
    test: bool,
    cmyk: bool,
    cover: Optional[str],
    cover_title: str,
    cover_subtitle: Optional[str]
):
    """
    mail2pdf - Convert Gmail emails to beautiful PDF booklets

    Creates stunning photo albums from your Gmail emails with
    customizable themes (Polaroid, Magazine, Minimal).
    """
    console.print(Panel.fit(
        "[bold blue]mail2pdf[/bold blue] - Email to PDF Converter",
        subtitle="Python Edition"
    ))

    # Load config
    cfg = load_config(config)

    # Determine theme
    theme_name = theme or cfg.get('theme', 'polaroid')
    theme_config = load_theme(theme_name)
    console.print(f"[green]Theme:[/green] {theme_config.get('name', theme_name)}")

    # Determine output path
    output_config = cfg.get('output', {})
    if output:
        output_path = output
    else:
        output_path = os.path.join(
            output_config.get('path', '/tmp/'),
            output_config.get('filename', 'gmail-export.pdf')
        )
    console.print(f"[green]Output:[/green] {output_path}")

    # Prepare cover data
    cover_data = None
    cover_image_path = cover or (PROJECT_DIR / 'cover.jpeg')
    if Path(cover_image_path).exists():
        cover_data = {
            'image_path': str(cover_image_path),
            'title': cover_title,
            'subtitle': cover_subtitle
        }
        console.print(f"[green]Cover:[/green] {cover_title}")

    # Test mode
    if test:
        run_test_mode(theme_config, output_path, verbose or debug, cmyk, cover_data)
        return

    # Initialize Gmail client
    gmail = GmailClient(cfg, verbose=verbose)

    # Authenticate
    with console.status("[bold green]Authenticating with Gmail..."):
        if not gmail.authenticate():
            console.print("[red]Authentication failed[/red]")
            sys.exit(1)

    # Save any new tokens
    new_access, new_refresh = gmail.get_new_tokens()
    if new_access:
        cfg['gmail']['access_token'] = new_access
    if new_refresh:
        cfg['gmail']['refresh_token'] = new_refresh
    save_config(cfg, config)
    console.print("[green]Tokens saved to config[/green]")

    # If only refreshing token, exit here
    if refresh_token:
        console.print("[green]Token refreshed successfully![/green]")
        return

    # Connect to IMAP
    with console.status("[bold green]Connecting to Gmail IMAP..."):
        if not gmail.connect():
            console.print("[red]Connection failed[/red]")
            sys.exit(1)

    try:
        # Get message count
        total = gmail.get_message_count(folder)
        console.print(f"[blue]Messages in {folder}:[/blue] {total}")

        # Fetch emails
        console.print(f"\n[bold]Fetching emails...[/bold]")
        if year:
            console.print(f"[yellow]Filtering by year:[/yellow] {year}")
        if limit:
            console.print(f"[yellow]Limit:[/yellow] {limit}")

        emails = gmail.fetch_emails(
            folder=folder,
            year=year,
            limit=limit,
            start=start
        )

        if not emails:
            console.print("[yellow]No emails with images found[/yellow]")
            return

        console.print(f"[green]Found {len(emails)} emails with images[/green]")

        # Process images and generate PDF
        generate_pdf(emails, theme_config, output_path, verbose or debug, cover_data)

    finally:
        gmail.disconnect()

    # Convert to CMYK for professional printing
    if cmyk:
        console.print("\n[bold]Converting to CMYK for professional printing...[/bold]")
        if convert_to_cmyk(output_path):
            console.print("[green]CMYK conversion successful[/green]")
        else:
            console.print("[yellow]PDF saved in RGB (CMYK conversion skipped)[/yellow]")

    console.print(f"\n[bold green]Done![/bold green] PDF saved to: {output_path}")


def generate_pdf(
    emails: List[Dict[str, Any]],
    theme: Dict[str, Any],
    output_path: str,
    verbose: bool,
    cover: Optional[Dict[str, Any]] = None
):
    """Process emails and generate PDF with parallel image processing"""
    pdf_generator = PDFGenerator(theme, TEMPLATES_DIR, verbose=verbose)

    # Determine number of workers (max 4 to avoid memory overhead)
    max_workers = min(4, max(1, multiprocessing.cpu_count() - 1))
    console.print(f"[blue]Using {max_workers} parallel workers[/blue]")

    pages = []
    temp_dirs_to_cleanup = []

    # Prepare work items: (email_data, theme_config, index)
    work_items = [(email, theme, idx) for idx, email in enumerate(emails)]

    with Progress(
        SpinnerColumn(),
        TextColumn("[progress.description]{task.description}"),
        BarColumn(),
        TaskProgressColumn(),
        console=console
    ) as progress:
        task = progress.add_task("[cyan]Processing emails (parallel)...", total=len(emails))

        # Process in parallel using ProcessPoolExecutor
        with ProcessPoolExecutor(max_workers=max_workers) as executor:
            # Submit all jobs
            future_to_idx = {
                executor.submit(process_single_email, item): item[2]
                for item in work_items
            }

            # Collect results as they complete
            for future in as_completed(future_to_idx):
                idx = future_to_idx[future]
                try:
                    result = future.result()
                    if result:
                        pages.append(result)
                except Exception as e:
                    console.print(f"[red]Error processing email {idx}: {e}[/red]")

                progress.update(task, advance=1)

    # Sort pages back to original order (by date or index)
    pages.sort(key=lambda p: p.get('_index', 0))

    # Remove the _index helper field
    for page in pages:
        page.pop('_index', None)

    # Generate PDF
    page_count = len(pages) + (1 if cover else 0)
    console.print(f"\n[bold]Generating PDF with {page_count} pages...[/bold]")
    pdf_generator.generate(pages, output_path, cover)

    # Cleanup temp files from workers
    import glob
    import tempfile
    temp_base = tempfile.gettempdir()
    for temp_dir in glob.glob(os.path.join(temp_base, 'mail2pdf_*')):
        try:
            shutil.rmtree(temp_dir)
        except Exception:
            pass

    console.print("[green]Processing complete[/green]")


def run_test_mode(theme: Dict[str, Any], output_path: str, verbose: bool, cmyk: bool = True, cover: Optional[Dict] = None):
    """Generate test PDF with sample data"""
    console.print("[yellow]Running in test mode with sample data[/yellow]")

    from datetime import datetime
    import urllib.request
    import tempfile

    # Download sample image
    sample_images = []
    with console.status("[bold green]Downloading sample image..."):
        try:
            # Use a simple placeholder image
            url = "https://picsum.photos/800/600"
            temp_dir = tempfile.mkdtemp()
            img_path = os.path.join(temp_dir, 'sample.jpg')

            # Download with redirect handling
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req) as response:
                with open(img_path, 'wb') as f:
                    f.write(response.read())

            sample_images = [{'path': img_path, 'index': 0}]
            console.print(f"[green]Sample image downloaded[/green]")
        except Exception as e:
            console.print(f"[yellow]Could not download sample image: {e}[/yellow]")
            console.print("[yellow]Generating PDF without images...[/yellow]")

    # Create sample pages
    pages = [
        {
            'date': datetime(2025, 3, 15),
            'subject': 'Unser Ausflug zum Zoo',
            'sender_name': 'Mama',
            'sender_email': 'mama@example.com',
            'text': 'Heute waren wir im Zoo! Die Elefanten waren besonders toll.',
            'images': sample_images,
            'rotation': -2.5
        },
        {
            'date': datetime(2025, 4, 20),
            'subject': 'Geburtstag von Emma',
            'sender_name': 'Papa',
            'sender_email': 'papa@example.com',
            'text': 'Emma hatte einen wunderschönen Geburtstag mit vielen Freunden.',
            'images': sample_images,
            'rotation': 1.8
        },
        {
            'date': datetime(2025, 5, 1),
            'subject': 'Erster Mai im Park',
            'sender_name': 'Oma',
            'sender_email': 'oma@example.com',
            'text': 'Ein herrlicher Frühlingstag mit der ganzen Familie.',
            'images': sample_images,
            'rotation': -1.2
        }
    ]

    # Generate PDF
    pdf_generator = PDFGenerator(theme, TEMPLATES_DIR, verbose=verbose)
    pdf_generator.generate(pages, output_path, cover)

    # Convert to CMYK for professional printing
    if cmyk:
        console.print("\n[bold]Converting to CMYK for professional printing...[/bold]")
        if convert_to_cmyk(output_path):
            console.print("[green]CMYK conversion successful[/green]")
        else:
            console.print("[yellow]PDF saved in RGB (CMYK conversion skipped)[/yellow]")

    console.print(f"\n[bold green]Test PDF generated![/bold green]")
    console.print(f"Open with: [cyan]open {output_path}[/cyan]")


if __name__ == '__main__':
    main()
