"""
Image Processing with Pillow
Handles image resizing, orientation, and grid layouts
"""

import io
import random
from pathlib import Path
from typing import List, Dict, Any, Tuple, Optional
from PIL import Image, ImageOps, ExifTags
import tempfile
import os


class ImageProcessor:
    """Process images for PDF generation"""

    def __init__(self, theme: Dict[str, Any], verbose: bool = False):
        self.theme = theme
        self.verbose = verbose
        self.temp_dir = tempfile.mkdtemp(prefix='mail2pdf_')
        self.image_counter = 0  # Global counter for unique filenames

        # Cache DPI and dimensions (avoid recalculating per image)
        self.dpi = theme.get('print', {}).get('dpi', 300)
        self.quality = theme.get('print', {}).get('quality', 95)
        max_width_mm = self._parse_mm(theme.get('photo', {}).get('max_width', '110mm'))
        max_height_mm = self._parse_mm(theme.get('photo', {}).get('max_height', '90mm'))
        self.max_width_px = int(max_width_mm * self.dpi / 25.4)
        self.max_height_px = int(max_height_mm * self.dpi / 25.4)

    def log(self, message: str):
        """Print verbose log messages"""
        if self.verbose:
            print(f"[Image] {message}")

    def cleanup(self):
        """Clean up temporary files"""
        import shutil
        if os.path.exists(self.temp_dir):
            shutil.rmtree(self.temp_dir)
            self.log(f"Cleaned up temp directory: {self.temp_dir}")

    def process_email_images(self, images: List[Dict]) -> List[Dict]:
        """
        Process all images from an email.
        Returns list of processed image info with file paths.
        """
        if not images:
            return []

        processed = []
        for idx, img_data in enumerate(images):
            try:
                path = self._process_single_image(img_data, idx)
                if path:
                    processed.append({
                        'path': path,
                        'index': idx
                    })
            except Exception as e:
                self.log(f"Error processing image {idx}: {e}")
                continue

        return processed

    def _process_single_image(self, img_data: Dict, index: int) -> Optional[str]:
        """Process a single image and save to temp file"""
        data = img_data.get('data')
        if not data:
            return None

        content_type = img_data.get('content_type', 'image/jpeg')

        # Skip non-JPEG/PNG (like Perl script skips some formats)
        if 'jpeg' not in content_type.lower() and 'jpg' not in content_type.lower() and 'png' not in content_type.lower():
            self.log(f"Skipping unsupported format: {content_type}")
            return None

        try:
            # Open image from bytes
            img = Image.open(io.BytesIO(data))
            self.log(f"Loaded image {index}: {img.size[0]}x{img.size[1]} {img.mode}")

            # Auto-orient based on EXIF
            img = self._auto_orient(img)

            # Convert to RGB if necessary (for JPEG output)
            if img.mode in ('RGBA', 'P'):
                img = img.convert('RGB')

            # Resize if needed (maintain aspect ratio) - use cached dimensions
            if img.width > self.max_width_px or img.height > self.max_height_px:
                img.thumbnail((self.max_width_px, self.max_height_px), Image.Resampling.LANCZOS)
                self.log(f"Resized to: {img.size[0]}x{img.size[1]}")

            # Save to temp file with unique name (use cached quality)
            self.image_counter += 1
            output_path = os.path.join(self.temp_dir, f'img_{self.image_counter:05d}.jpg')
            img.save(output_path, 'JPEG', quality=self.quality, optimize=True)
            self.log(f"Saved to: {output_path}")

            return output_path

        except Exception as e:
            self.log(f"Error processing image: {e}")
            return None

    def _auto_orient(self, img: Image.Image) -> Image.Image:
        """Auto-orient image based on EXIF data"""
        try:
            # Use PIL's built-in EXIF orientation handling
            img = ImageOps.exif_transpose(img)
        except Exception as e:
            self.log(f"Could not auto-orient: {e}")
        return img

    def _parse_mm(self, value: str) -> float:
        """Parse mm value from string like '110mm'"""
        if isinstance(value, (int, float)):
            return float(value)
        if isinstance(value, str):
            return float(value.replace('mm', '').strip())
        return 100.0  # default

    def create_grid(self, images: List[Dict], count: int) -> Optional[str]:
        """
        Create a grid/montage of multiple images.
        Returns path to combined image.
        """
        if count <= 1:
            return None

        grid_config = self.theme.get('grid', {})
        layouts = grid_config.get('layouts', {})

        # Determine grid layout
        layout = layouts.get(str(count), layouts.get(count, '2x2'))
        cols, rows = self._parse_layout(layout, count)

        self.log(f"Creating {cols}x{rows} grid for {count} images")

        # Get dimensions (use cached DPI)
        gap = self._parse_mm(grid_config.get('gap', '4mm'))
        gap_px = int(gap * self.dpi / 25.4)

        # Calculate cell size
        cell_width = (self.max_width_px - (cols - 1) * gap_px) // cols
        cell_height = (self.max_height_px - (rows - 1) * gap_px) // rows

        # Create canvas with Polaroid background color (#fff9f0)
        polaroid_bg = (255, 249, 240)
        canvas = Image.new('RGB', (self.max_width_px, self.max_height_px), polaroid_bg)

        # Place images
        for idx, img_info in enumerate(images[:count]):
            if idx >= cols * rows:
                break

            row = idx // cols
            col = idx % cols

            x = col * (cell_width + gap_px)
            y = row * (cell_height + gap_px)

            try:
                img = Image.open(img_info['path'])
                # Use thumbnail (preserves aspect ratio) instead of fit (crops)
                img.thumbnail((cell_width, cell_height), Image.Resampling.LANCZOS)
                # Center image in cell
                offset_x = (cell_width - img.width) // 2
                offset_y = (cell_height - img.height) // 2
                canvas.paste(img, (x + offset_x, y + offset_y))
            except Exception as e:
                self.log(f"Error placing image {idx} in grid: {e}")

        # Save grid with unique name (use cached quality)
        self.image_counter += 1
        output_path = os.path.join(self.temp_dir, f'grid_{self.image_counter:05d}.jpg')
        canvas.save(output_path, 'JPEG', quality=self.quality)
        self.log(f"Grid saved to: {output_path}")

        return output_path

    def _parse_layout(self, layout: str, count: int) -> Tuple[int, int]:
        """Parse layout string like '2x3' into (cols, rows)"""
        if 'x' in str(layout):
            parts = str(layout).split('x')
            cols = int(parts[0])
            if parts[1]:
                rows = int(parts[1])
            else:
                # Auto-calculate rows
                rows = (count + cols - 1) // cols
            return cols, rows

        # Default layouts by count
        defaults = {
            2: (2, 1),
            3: (2, 2),
            4: (2, 2),
            5: (3, 2),
            6: (3, 2),
            7: (4, 2),
            8: (4, 2),
            9: (3, 3),
            10: (5, 2),
        }
        return defaults.get(count, (2, 2))

    def get_rotation(self) -> float:
        """Get random rotation value based on theme settings"""
        photo_config = self.theme.get('photo', {})
        rot_min = photo_config.get('rotation_min', 0)
        rot_max = photo_config.get('rotation_max', 0)

        if rot_min == 0 and rot_max == 0:
            return 0

        return random.uniform(rot_min, rot_max)
