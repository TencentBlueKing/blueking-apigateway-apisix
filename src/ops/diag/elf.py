"""Bounded ELF PT_NOTE reader; never maps or reads process memory."""
import os
from pathlib import Path
import stat
import struct


def build_id(path: Path):
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode):
                return None
            header = stream.read(64)
            if len(header) < 64 or header[:4] != b'\x7fELF' or header[4] not in (1, 2) or header[5] not in (1, 2):
                return None
            endian = '<' if header[5] == 1 else '>'
            is64 = header[4] == 2
            if is64:
                offset = struct.unpack_from(endian + 'Q', header, 32)[0]
                size, count = struct.unpack_from(endian + 'HH', header, 54)
            else:
                offset = struct.unpack_from(endian + 'I', header, 28)[0]
                size, count = struct.unpack_from(endian + 'HH', header, 42)
            expected = 56 if is64 else 32
            if size != expected or count > 128 or offset + count * size > info.st_size:
                return None
            stream.seek(offset)
            table = stream.read(count * size)
            remaining = 65536
            for index in range(count):
                ph = struct.unpack_from(endian + ('IIQQQQQQ' if is64 else 'IIIIIIII'), table, index * size)
                if ph[0] != 4:
                    continue
                start, length = (ph[2], ph[5]) if is64 else (ph[1], ph[4])
                if length > remaining or start + length > info.st_size:
                    return None
                remaining -= length
                stream.seek(start)
                notes = stream.read(length)
                cursor = 0
                while cursor + 12 <= len(notes):
                    namesize, descsize, kind = struct.unpack_from(endian + 'III', notes, cursor)
                    cursor += 12
                    name_end = cursor + namesize
                    desc_start = cursor + ((namesize + 3) & ~3)
                    end = desc_start + descsize
                    if end > len(notes):
                        return None
                    if kind == 3 and notes[cursor:name_end] == b'GNU\0' and 0 < descsize <= 64:
                        return notes[desc_start:end].hex()
                    cursor = desc_start + ((descsize + 3) & ~3)
    except (OSError, ValueError, struct.error, OverflowError):
        return None
    return None
