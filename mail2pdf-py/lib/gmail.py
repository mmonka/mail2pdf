"""
Gmail IMAP + OAuth2 Integration
Handles authentication and email fetching from Gmail
"""

import base64
import email
from email.header import decode_header
from datetime import datetime
from typing import Optional, List, Dict, Any, Tuple
from pathlib import Path
import json

import time
from imapclient import IMAPClient
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from google_auth_oauthlib.flow import InstalledAppFlow

# Gmail API Scopes
SCOPES = ['https://mail.google.com/']


class GmailClient:
    """Gmail IMAP client with OAuth2 authentication"""

    def __init__(self, config: Dict[str, Any], verbose: bool = False):
        self.config = config
        self.verbose = verbose
        self.imap: Optional[IMAPClient] = None
        self.credentials: Optional[Credentials] = None

    def log(self, message: str):
        """Print verbose log messages"""
        if self.verbose:
            print(f"[Gmail] {message}")

    def authenticate(self) -> bool:
        """
        Authenticate with Gmail using OAuth2.
        Returns True if successful.
        """
        gmail_config = self.config.get('gmail', {})

        # Check if we have existing tokens
        access_token = gmail_config.get('access_token', '')
        refresh_token = gmail_config.get('refresh_token', '')

        if refresh_token:
            self.log("Found refresh token, getting fresh access token...")
            self.credentials = Credentials(
                token=access_token or None,
                refresh_token=refresh_token,
                token_uri='https://oauth2.googleapis.com/token',
                client_id=gmail_config.get('client_id'),
                client_secret=gmail_config.get('client_secret'),
                scopes=SCOPES
            )

            # Always refresh to get a fresh token (tokens expire after 1 hour)
            try:
                self.log("Refreshing access token...")
                self.credentials.refresh(Request())
                self.log(f"Token refreshed successfully")
                return True
            except Exception as e:
                self.log(f"Token refresh failed: {e}")
                self.log("Will try full OAuth flow...")

        # Need to do full OAuth flow
        self.log("Starting OAuth flow (browser will open)...")
        self.credentials = self._run_oauth_flow(gmail_config)

        return self.credentials is not None

    def _run_oauth_flow(self, gmail_config: Dict) -> Optional[Credentials]:
        """Run the OAuth2 authorization flow"""
        client_id = gmail_config.get('client_id')
        client_secret = gmail_config.get('client_secret')

        if not client_id or not client_secret:
            print("ERROR: client_id and client_secret required in config.yaml")
            print("Get these from Google Cloud Console > APIs & Services > Credentials")
            return None

        # Create OAuth flow
        client_config = {
            "installed": {
                "client_id": client_id,
                "client_secret": client_secret,
                "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                "token_uri": "https://oauth2.googleapis.com/token",
                "redirect_uris": ["http://localhost"]
            }
        }

        flow = InstalledAppFlow.from_client_config(client_config, SCOPES)
        credentials = flow.run_local_server(port=0)

        self.log("OAuth flow completed successfully")
        return credentials

    def get_new_tokens(self) -> Tuple[str, str]:
        """Return current access and refresh tokens for saving"""
        if self.credentials:
            return self.credentials.token, self.credentials.refresh_token
        return '', ''

    def connect(self) -> bool:
        """Connect to Gmail IMAP server"""
        if not self.credentials:
            print("ERROR: Not authenticated. Call authenticate() first.")
            return False

        try:
            self.log("Connecting to imap.gmail.com...")

            # Build OAuth2 string for IMAP
            username = self.config['gmail']['username']
            auth_string = f"user={username}\x01auth=Bearer {self.credentials.token}\x01\x01"

            # Connect to Gmail IMAP
            self.imap = IMAPClient('imap.gmail.com', ssl=True)
            self.imap.oauth2_login(username, self.credentials.token)

            self.log("Connected successfully")
            return True

        except Exception as e:
            print(f"ERROR: Failed to connect to Gmail: {e}")
            return False

    def disconnect(self):
        """Disconnect from IMAP server"""
        if self.imap:
            try:
                self.imap.logout()
            except:
                pass
            self.imap = None

    def get_message_count(self, folder: str = 'INBOX') -> int:
        """Get total number of messages in folder"""
        if not self.imap:
            return 0

        self.imap.select_folder(folder, readonly=True)
        messages = self.imap.search(['ALL'])
        return len(messages)

    def fetch_emails(
            self,
            folder: str = 'INBOX',
            year: Optional[int] = None,
            limit: Optional[int] = None,
            start: int = 0,
            batch_size: int = 100
    ) -> List[Dict[str, Any]]:
        """
        Fetch emails from Gmail using batch fetching for performance.

        Args:
            folder: IMAP folder name (default: INBOX)
            year: Filter by year (optional)
            limit: Maximum number of emails to fetch (optional)
            start: Start index for pagination (default: 0)
            batch_size: Number of emails to fetch per batch (default: 25)

        Returns:
            List of email dictionaries with headers and body parts
        """
        if not self.imap:
            print("ERROR: Not connected. Call connect() first.")
            return []

        self.log(f"Selecting folder: {folder}")
        self.imap.select_folder(folder, readonly=True)

        # Build search criteria
        criteria = ['ALL']
        if year:
            criteria = [
                'SINCE', f'1-Jan-{year}',
                'BEFORE', f'1-Jan-{year + 1}'
            ]

        self.log(f"Searching with criteria: {criteria}")
        message_ids = self.imap.search(criteria)
        total = len(message_ids)
        self.log(f"Found {total} messages")

        # Apply start/limit
        if start > 0:
            message_ids = message_ids[start:]
        if limit:
            message_ids = message_ids[:limit]

        total_to_fetch = len(message_ids)
        self.log(f"Will fetch {total_to_fetch} messages in batches of {batch_size}")

        # PERFORMANCE: Batch fetch emails with rate limit handling
        emails = []
        total_batches = (total_to_fetch + batch_size - 1) // batch_size
        retry_delay = 2  # Start with 2 seconds

        for batch_start in range(0, total_to_fetch, batch_size):
            batch_end = min(batch_start + batch_size, total_to_fetch)
            batch_ids = message_ids[batch_start:batch_end]
            batch_num = batch_start // batch_size + 1

            self.log(f"Fetching batch {batch_num}/{total_batches} ({len(batch_ids)} emails)")

            # Retry logic for rate limits
            max_retries = 5
            for attempt in range(max_retries):
                try:
                    # Fetch entire batch in ONE request
                    response = self.imap.fetch(batch_ids, ['RFC822'])

                    for msg_id in batch_ids:
                        try:
                            if msg_id not in response:
                                continue

                            raw_email = response[msg_id][b'RFC822']
                            email_data = self._parse_email(raw_email, msg_id)

                            if email_data:
                                if email_data['images'] or not email_data.get('has_video', False):
                                    emails.append(email_data)

                        except Exception as e:
                            self.log(f"Error parsing message {msg_id}: {e}")
                            continue

                    # Success - add small delay to avoid rate limits
                    time.sleep(0.5)
                    retry_delay = 2  # Reset delay on success
                    break  # Exit retry loop

                except Exception as e:
                    error_str = str(e)
                    if 'OVERQUOTA' in error_str or 'exceeded' in error_str.lower():
                        if attempt < max_retries - 1:
                            self.log(f"Rate limit hit, waiting {retry_delay}s before retry {attempt + 2}/{max_retries}...")
                            time.sleep(retry_delay)
                            retry_delay = min(retry_delay * 2, 60)  # Exponential backoff, max 60s

                            # Reconnect IMAP
                            try:
                                self.imap.logout()
                            except:
                                pass
                            self.connect()
                            self.imap.select_folder('INBOX', readonly=True)
                        else:
                            self.log(f"Failed after {max_retries} retries: {e}")
                    else:
                        self.log(f"Error fetching batch: {e}")
                        break

        self.log(f"Fetched {len(emails)} emails with images")
        return emails

    def _parse_email(self, raw_email: bytes, msg_id: int) -> Optional[Dict[str, Any]]:
        """Parse a raw email into structured data"""
        msg = email.message_from_bytes(raw_email)

        # Extract headers
        subject = self._decode_header(msg.get('Subject', ''))
        from_header = self._decode_header(msg.get('From', ''))
        date_str = msg.get('Date', '')

        # Skip Facebook emails
        if 'facebook' in from_header.lower():
            return None

        # Parse date
        date_obj = self._parse_date(date_str)

        # Parse sender
        sender_name, sender_email = self._parse_from(from_header)

        # Extract body parts
        text_content = ''
        images = []
        has_video = False

        for part in msg.walk():
            content_type = part.get_content_type()

            if content_type == 'text/plain':
                payload = part.get_payload(decode=True)
                if payload:
                    charset = part.get_content_charset() or 'utf-8'
                    try:
                        text_content += payload.decode(charset, errors='replace')
                    except:
                        text_content += payload.decode('utf-8', errors='replace')

            elif content_type.startswith('image/'):
                payload = part.get_payload(decode=True)
                if payload:
                    filename = part.get_filename() or f'image_{len(images)}.jpg'
                    images.append({
                        'data': payload,
                        'filename': filename,
                        'content_type': content_type
                    })

            elif content_type.startswith('video/'):
                has_video = True

        text_content = self._clean_text(text_content)

        return {
            'id': msg_id,
            'subject': subject,
            'from': from_header,
            'sender_name': sender_name,
            'sender_email': sender_email,
            'date': date_obj,
            'date_str': date_str,
            'text': text_content,
            'images': images,
            'has_video': has_video
        }

    def _decode_header(self, header: str) -> str:
        """Decode email header (handles MIME encoding)"""
        if not header:
            return ''

        decoded_parts = decode_header(header)
        result = []
        for data, charset in decoded_parts:
            if isinstance(data, bytes):
                charset = charset or 'utf-8'
                try:
                    result.append(data.decode(charset, errors='replace'))
                except:
                    result.append(data.decode('utf-8', errors='replace'))
            else:
                result.append(data)
        return ''.join(result)

    def _parse_date(self, date_str: str) -> Optional[datetime]:
        """Parse email date string to datetime"""
        if not date_str:
            return None

        # Common email date formats
        formats = [
            '%a, %d %b %Y %H:%M:%S %z',
            '%d %b %Y %H:%M:%S %z',
            '%a, %d %b %Y %H:%M:%S',
            '%d %b %Y %H:%M:%S',
        ]

        # Remove timezone name in parentheses if present
        import re
        date_str = re.sub(r'\s*\([^)]+\)\s*$', '', date_str)

        for fmt in formats:
            try:
                return datetime.strptime(date_str.strip(), fmt)
            except ValueError:
                continue

        self.log(f"Could not parse date: {date_str}")
        return None

    def _parse_from(self, from_header: str) -> Tuple[str, str]:
        """Parse From header into name and email"""
        import re

        # Pattern: "Name" <email> or Name <email> or just email
        match = re.match(r'^"?([^"<]+)"?\s*<([^>]+)>$', from_header)
        if match:
            return match.group(1).strip(), match.group(2).strip()

        match = re.match(r'^([^<]+)<([^>]+)>$', from_header)
        if match:
            return match.group(1).strip(), match.group(2).strip()

        # Just email address
        if '@' in from_header:
            return '', from_header.strip()

        return from_header.strip(), ''

    def _clean_text(self, text: str) -> str:
        """Clean email text content"""
        if not text:
            return ''

        # Remove common email footers
        stop_phrases = [
            'Gesendet von meinem iPhone',
            'Von meinem iPhone gesendet',
            'Gesendet mit der GMX-App',
            'Sent from my iPhone',
        ]

        lines = text.split('\n')
        cleaned_lines = []

        for line in lines:
            # Check for stop phrases
            should_stop = False
            for phrase in stop_phrases:
                if phrase.lower() in line.lower():
                    should_stop = True
                    break
            if should_stop:
                break

            # Clean line
            line = line.strip()
            if line:
                cleaned_lines.append(line)

        return ' '.join(cleaned_lines)
