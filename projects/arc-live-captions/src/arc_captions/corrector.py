#
#  Copyright (c) 2025-2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

import httpx


PROMPT = """You are correcting one line of live captions for a graduation ceremony.

Reference list of names and terms (graduates, faculty, programs):
{names}

Rules:
1. Correct only obviously misheard proper nouns and terms from the list.
2. Preserve every other word exactly as given.
3. Do not add commentary, do not rephrase, do not invent content.
4. Return only the corrected line, nothing else.

Line: {text}
Corrected:"""


class NameCorrector:
    def __init__(self, ollama_url: str, model: str, names: list[str], timeout_s: float = 2.0):
        self.ollama_url = ollama_url.rstrip("/")
        self.model = model
        self.names_block = "\n".join(f"- {n}" for n in names)
        self.client = httpx.Client(timeout=timeout_s)

    def correct(self, text: str) -> str:
        text = text.strip()
        if not text:
            return text
        try:
            r = self.client.post(
                f"{self.ollama_url}/api/generate",
                json={
                    "model": self.model,
                    "prompt": PROMPT.format(names=self.names_block, text=text),
                    "stream": False,
                    "options": {"temperature": 0.0, "num_predict": 256},
                },
            )
            r.raise_for_status()
            corrected = r.json().get("response", "").strip()
            return corrected or text
        except Exception as e:
            print(f"[corrector] fallback to uncorrected: {e}")
            return text

    def close(self) -> None:
        self.client.close()
