#
#  Copyright (c) 2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""PDF parser using pdfplumber — tables first, text fallback."""

from typing import Optional

from schema import ROSDocument


def parse_pdf(path: str, event_name: Optional[str] = None) -> Optional[ROSDocument]:
    """Extract agenda from PDF. Tries table extraction first, falls back to text regex."""
    try:
        import pdfplumber
    except ImportError:
        raise ImportError("pdfplumber is required for PDF parsing: pip install pdfplumber")

    text_blocks = []
    with pdfplumber.open(path) as pdf:
        for page in pdf.pages:
            # Try structured tables first
            tables = page.extract_tables()
            if tables:
                for table in tables:
                    for row in table:
                        if row and any(cell for cell in row if cell):
                            # Join non-empty cells with tab separation
                            line = "\t".join(cell.strip() for cell in row if cell)
                            text_blocks.append(line)
            else:
                # Fall back to full text extraction
                text = page.extract_text()
                if text:
                    text_blocks.append(text)

    if not text_blocks:
        return None

    full_text = "\n".join(text_blocks)

    # Use the text parser on the extracted content
    from .text_parser import parse_text
    return parse_text(full_text, event_name=event_name)
