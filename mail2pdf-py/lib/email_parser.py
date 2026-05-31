"""
Email Parser Utilities
Helper functions for parsing email content
"""

import re
from typing import Tuple, Optional
from datetime import datetime


def parse_from_header(from_header: str) -> Tuple[str, str]:
    """
    Parse From header into name and email.

    Args:
        from_header: Raw From header string

    Returns:
        Tuple of (name, email)
    """
    if not from_header:
        return '', ''

    # Pattern: "Name" <email@example.com>
    match = re.match(r'^"([^"]+)"\s*<([^>]+)>$', from_header)
    if match:
        return match.group(1).strip(), match.group(2).strip()

    # Pattern: Name <email@example.com>
    match = re.match(r'^([^<]+)<([^>]+)>$', from_header)
    if match:
        return match.group(1).strip(), match.group(2).strip()

    # Just email address
    if '@' in from_header:
        return '', from_header.strip()

    return from_header.strip(), ''


def clean_email_text(text: str) -> str:
    """
    Clean email text content by removing signatures and footers.

    Args:
        text: Raw email text

    Returns:
        Cleaned text
    """
    if not text:
        return ''

    # Common email footers to remove
    stop_phrases = [
        'gesendet von meinem iphone',
        'von meinem iphone gesendet',
        'gesendet mit der gmx-app',
        'sent from my iphone',
        'sent from my mobile',
        'get outlook for',
        '-- ',  # Signature delimiter
    ]

    lines = text.split('\n')
    cleaned_lines = []

    for line in lines:
        line_lower = line.lower().strip()

        # Check for stop phrases
        should_stop = any(phrase in line_lower for phrase in stop_phrases)
        if should_stop:
            break

        # Skip empty lines at the beginning
        if not cleaned_lines and not line.strip():
            continue

        cleaned_lines.append(line.strip())

    # Join and clean up whitespace
    result = ' '.join(cleaned_lines)
    result = re.sub(r'\s+', ' ', result)  # Collapse multiple spaces
    return result.strip()


def format_date_german(date: Optional[datetime]) -> str:
    """
    Format datetime in German style.

    Args:
        date: datetime object

    Returns:
        Formatted string like "15. März"
    """
    if not date:
        return ''

    month_names = [
        '', 'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni',
        'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'
    ]

    month_name = month_names[date.month] if 1 <= date.month <= 12 else str(date.month)
    return f"{date.day}. {month_name}"


def truncate_text(text: str, max_length: int = 150, suffix: str = '...') -> str:
    """
    Truncate text to maximum length.

    Args:
        text: Text to truncate
        max_length: Maximum length
        suffix: Suffix to add if truncated

    Returns:
        Truncated text
    """
    if not text or len(text) <= max_length:
        return text

    return text[:max_length - len(suffix)] + suffix


def is_valid_image_type(content_type: str) -> bool:
    """
    Check if content type is a supported image format.

    Args:
        content_type: MIME content type

    Returns:
        True if supported image type
    """
    supported = ['image/jpeg', 'image/jpg', 'image/png', 'image/gif']
    return content_type.lower() in supported
