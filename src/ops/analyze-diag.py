#!/usr/bin/python3
"""Run on an external Linux analysis machine, never from the collector."""
import argparse
from pathlib import Path
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from diag.offline import analyze


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--symbols', type=Path)
    args = parser.parse_args()
    try:
        print(analyze(args.bundle, args.symbols))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print('Evidence rejected: ' + str(exc), file=sys.stderr)
        return 20
    return 0


if __name__ == '__main__':
    sys.exit(main())
