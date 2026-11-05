"""robo-agent serve"""

from __future__ import annotations

import argparse
import sys

from . import config


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="robo-agent", description="Robo's chat service.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve", help="serve the app's API on 127.0.0.1")
    parser.parse_args(argv)
    from .server import serve

    serve(config.load())
    return 0


if __name__ == "__main__":
    sys.exit(main())
