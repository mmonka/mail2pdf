"""
PDF Generator using WeasyPrint and Jinja2
Creates beautiful PDF layouts from email data
"""

import os
from pathlib import Path
from typing import List, Dict, Any, Optional
from datetime import datetime

from jinja2 import Environment, FileSystemLoader
from weasyprint import HTML, CSS
from weasyprint.text.fonts import FontConfiguration


# German month names
MONTH_NAMES = [
    '', 'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
    'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'
]


class PDFGenerator:
    """Generate PDF from email data using WeasyPrint"""

    def __init__(self, theme: Dict[str, Any], templates_dir: Path, verbose: bool = False):
        self.theme = theme
        self.verbose = verbose
        self.templates_dir = templates_dir

        # Setup Jinja2
        self.jinja_env = Environment(
            loader=FileSystemLoader(str(templates_dir)),
            autoescape=True
        )

        # Font configuration for WeasyPrint
        self.font_config = FontConfiguration()

    def log(self, message: str):
        """Print verbose log messages"""
        if self.verbose:
            print(f"[PDF] {message}")

    def generate(self, pages: List[Dict[str, Any]], output_path: str, cover: Optional[Dict] = None) -> bool:
        """
        Generate PDF from page data.

        Args:
            pages: List of page dictionaries with email data and image paths
            output_path: Path for output PDF file
            cover: Optional cover page dict with 'image_path', 'title', 'subtitle'

        Returns:
            True if successful
        """
        try:
            self.log(f"Generating PDF with {len(pages)} polaroids")
            if cover:
                self.log(f"Cover: {cover.get('title', 'No title')}")
            self.log(f"Theme: {self.theme.get('name', 'Unknown')}")

            # Prepare pages with formatted data
            formatted_pages = [self._format_page(p) for p in pages]

            # Check if we need to group pages (multiple polaroids per page)
            photos_per_page = self.theme.get('layout', {}).get('photos_per_page', 1)

            if photos_per_page > 1:
                # Group polaroids into pages
                grouped_pages = self._group_pages(formatted_pages, photos_per_page)
                self.log(f"Grouped into {len(grouped_pages)} A4 pages ({photos_per_page} polaroids each)")
            else:
                # Each polaroid is its own page
                grouped_pages = [[p] for p in formatted_pages]

            # Generate CSS from theme
            css_content = self._render_css()

            # Render HTML
            html_content = self._render_html_grouped(grouped_pages, css_content, cover)

            # Debug: save HTML for inspection
            if self.verbose:
                debug_html = output_path.replace('.pdf', '_debug.html')
                with open(debug_html, 'w', encoding='utf-8') as f:
                    f.write(html_content)
                self.log(f"Debug HTML saved to: {debug_html}")

            # Generate PDF with WeasyPrint
            self.log("Rendering PDF with WeasyPrint...")
            html = HTML(string=html_content, base_url=str(self.templates_dir))
            html.write_pdf(output_path, font_config=self.font_config)

            self.log(f"PDF saved to: {output_path}")
            return True

        except Exception as e:
            print(f"ERROR: Failed to generate PDF: {e}")
            import traceback
            traceback.print_exc()
            return False

    def _group_pages(self, pages: List[Dict], per_page: int) -> List[List[Dict]]:
        """Group polaroids into pages"""
        grouped = []
        for i in range(0, len(pages), per_page):
            grouped.append(pages[i:i + per_page])
        return grouped

    def _render_html_grouped(self, grouped_pages: List[List[Dict]], css: str, cover: Optional[Dict] = None) -> str:
        """Render HTML for grouped pages (multiple polaroids per page)"""
        template = self.jinja_env.get_template('base.html')
        return template.render(
            grouped_pages=grouped_pages,
            pages=[p for group in grouped_pages for p in group],  # Flat list for backwards compat
            theme=self.theme,
            css=css,
            title="Email Album",
            multi_per_page=self.theme.get('layout', {}).get('photos_per_page', 1) > 1,
            cover=cover
        )

    def _format_page(self, page: Dict[str, Any]) -> Dict[str, Any]:
        """Format page data for template rendering"""
        date_obj = page.get('date')

        # Format date nicely
        if date_obj:
            day = date_obj.day
            month = date_obj.month
            year = date_obj.year
            month_name = MONTH_NAMES[month] if 1 <= month <= 12 else str(month)
            date_formatted = f"{day}. {month_name}"
        else:
            date_formatted = ""
            year = ""

        # Truncate text preview
        text = page.get('text', '')
        text_preview = text[:150] + '...' if len(text) > 150 else text

        # Truncate subject if too long
        subject = page.get('subject', '')
        if len(subject) > 60:
            subject = subject[:57] + '...'

        return {
            'date_formatted': date_formatted,
            'year': year,
            'subject': subject,
            'sender_name': page.get('sender_name', ''),
            'sender_email': page.get('sender_email', ''),
            'text_preview': text_preview,
            'images': page.get('images', []),
            'rotation': page.get('rotation', 0),
            'has_images': len(page.get('images', [])) > 0
        }

    def _render_css(self) -> str:
        """Render CSS from theme using Jinja2"""
        try:
            template = self.jinja_env.get_template('styles.css')
            return template.render(theme=self.theme)
        except Exception as e:
            self.log(f"Error rendering CSS: {e}")
            return self._fallback_css()

    def _render_html(self, pages: List[Dict], css: str) -> str:
        """Render HTML from template"""
        template = self.jinja_env.get_template('base.html')
        return template.render(
            pages=pages,
            theme=self.theme,
            css=css,
            title="Email Album"
        )

    def _fallback_css(self) -> str:
        """Minimal fallback CSS if template fails"""
        return """
        @page { size: A5; margin: 0; }
        body { font-family: sans-serif; }
        .page {
            width: 148mm;
            height: 210mm;
            padding: 15mm;
            page-break-after: always;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
        }
        .polaroid {
            background: white;
            padding: 8mm 8mm 25mm 8mm;
            box-shadow: 0 4px 12px rgba(0,0,0,0.2);
        }
        .photo { max-width: 100%; height: auto; }
        .caption { text-align: center; padding-top: 8mm; }
        .date { font-size: 18pt; color: #666; }
        .subject { font-size: 14pt; margin-top: 4mm; }
        """
