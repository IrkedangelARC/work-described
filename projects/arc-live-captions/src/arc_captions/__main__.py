#
#  Copyright (c) 2025-2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

import argparse
import sys


def main() -> int:
    p = argparse.ArgumentParser(prog="arc-live-captions")
    p.add_argument("--config", "-c", default="config.yaml", help="path to config YAML")
    p.add_argument("--list-devices", action="store_true", help="list audio input devices and exit")
    p.add_argument("--test-ingestion", metavar="URL", help="POST a test caption to URL and exit")
    args = p.parse_args()

    if args.list_devices:
        import sounddevice as sd
        print(sd.query_devices())
        return 0

    if args.test_ingestion:
        from .ingestion import YouTubeCaptions
        yt = YouTubeCaptions(args.test_ingestion)
        ok = yt.send("arc-live-captions test message")
        yt.close()
        print("Test caption sent." if ok else "Test caption FAILED.")
        return 0 if ok else 1

    from .pipeline import run
    run(args.config)
    return 0


if __name__ == "__main__":
    sys.exit(main())
