"""Isolated bounded smaps_rollup read. Never falls back to smaps."""
import json
import os
import sys

FIELDS = {'Rss', 'Pss', 'Pss_Anon', 'Pss_File', 'Pss_Shmem', 'Shared_Clean',
          'Shared_Dirty', 'Private_Clean', 'Private_Dirty', 'Swap', 'SwapPss'}


def main():
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        data = stream.read(65537)
    if len(data) > 65536:
        return 1
    values = {}
    for line in data.decode().splitlines():
        words = line.split()
        if words and words[0].rstrip(':') in FIELDS:
            values[words[0].rstrip(':')] = int(words[1])
    print(json.dumps(values))
    return 0 if values else 1


if __name__ == '__main__':
    sys.exit(main())
