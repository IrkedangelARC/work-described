#
#  Copyright (c) 2025-2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

from datetime import datetime, timezone

import httpx


class YouTubeCaptions:
    def __init__(self, ingest_url: str, timeout_s: float = 5.0):
        if "seq=" not in ingest_url:
            raise ValueError("ingest URL must contain 'seq=' parameter (YouTube format)")
        self.base_url = ingest_url.rsplit("seq=", 1)[0] + "seq="
        self.seq = 1
        self.client = httpx.Client(timeout=timeout_s)

    def send(self, text: str) -> bool:
        text = text.strip()
        if not text:
            return False
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3]
        body = f"{ts}\n{text}\n\n"
        try:
            r = self.client.post(
                f"{self.base_url}{self.seq}",
                content=body,
                headers={"Content-Type": "text/plain"},
            )
            r.raise_for_status()
            self.seq += 1
            return True
        except Exception as e:
            print(f"[ingestion] send failed (seq={self.seq}): {e}")
            return False

    def close(self) -> None:
        self.client.close()
