#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""Claude API fallback parser for unstructured/scanned agenda documents."""

import base64
import json
import os
from pathlib import Path
from typing import Optional

from schema import ROSDocument, ROSSession

_SYSTEM_PROMPT = """You are an AV production assistant. Extract agenda/schedule sessions from the provided document.

Return ONLY valid JSON matching this schema (no markdown, no explanation):
{
  "event_name": "string or null",
  "event_date": "YYYY-MM-DD or null",
  "venue": "string or null",
  "sessions": [
    {
      "time_range": "9:00 AM - 9:45 AM",
      "session_title": "Session Name",
      "speakers": "Speaker Name(s) or null",
      "format": "keynote|panel|fireside|lightning|remarks|social|break|transition|other",
      "duration_minutes": 45,
      "notes": "any relevant notes or null"
    }
  ]
}

Rules:
- Extract ALL sessions/agenda items in chronological order
- Compute duration_minutes from time ranges when possible
- Infer format from context (keynote, panel, break, etc.)
- Preserve original session titles exactly as written
- If a time range is ambiguous, include your best interpretation"""


def parse_with_ai(
    path: str,
    event_name: Optional[str] = None,
    model: str = "claude-sonnet-4-20250514",
) -> Optional[ROSDocument]:
    """Send document to Claude API and parse the response into ROSDocument."""
    try:
        import anthropic
    except ImportError:
        raise ImportError("anthropic is required for AI parsing: pip install anthropic")

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise RuntimeError("ANTHROPIC_API_KEY environment variable not set")

    client = anthropic.Anthropic(api_key=api_key)
    file_path = Path(path)
    suffix = file_path.suffix.lower()

    # Build message content based on file type
    content = []
    if suffix == ".pdf":
        with open(path, "rb") as f:
            b64 = base64.standard_b64encode(f.read()).decode()
        content.append({
            "type": "document",
            "source": {"type": "base64", "media_type": "application/pdf", "data": b64},
        })
    elif suffix in (".png", ".jpg", ".jpeg", ".gif", ".webp"):
        media_types = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                       ".gif": "image/gif", ".webp": "image/webp"}
        with open(path, "rb") as f:
            b64 = base64.standard_b64encode(f.read()).decode()
        content.append({
            "type": "image",
            "source": {"type": "base64", "media_type": media_types[suffix], "data": b64},
        })
    else:
        # Text-based files
        text = file_path.read_text(encoding="utf-8", errors="replace")
        content.append({"type": "text", "text": text})

    prompt = "Extract all agenda/schedule sessions from this document."
    if event_name:
        prompt += f' The event is called "{event_name}".'
    content.append({"type": "text", "text": prompt})

    response = client.messages.create(
        model=model,
        max_tokens=4096,
        system=_SYSTEM_PROMPT,
        messages=[{"role": "user", "content": content}],
    )

    # Parse response JSON
    response_text = response.content[0].text.strip()
    # Strip markdown code fences if present
    if response_text.startswith("```"):
        lines = response_text.split("\n")
        response_text = "\n".join(lines[1:-1] if lines[-1].strip() == "```" else lines[1:])

    data = json.loads(response_text)

    sessions = []
    for s in data.get("sessions", []):
        sessions.append(ROSSession(
            session_title=s.get("session_title", "Untitled"),
            time_range=s.get("time_range"),
            subtitle=s.get("subtitle"),
            speakers=s.get("speakers"),
            format=s.get("format"),
            duration_minutes=s.get("duration_minutes"),
            notes=s.get("notes"),
            is_break=s.get("is_break"),
            is_transition=s.get("is_transition"),
        ))

    if not sessions:
        return None

    return ROSDocument(
        event_name=event_name or data.get("event_name"),
        event_date=data.get("event_date"),
        venue=data.get("venue"),
        sessions=sessions,
    )
