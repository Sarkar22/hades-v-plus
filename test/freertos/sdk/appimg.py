# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# appimg.py -- the image tool of the app SDK: images and Intel HEX files for the app loader of
# the FreeRTOS shell (test/freertos/loader/SPEC.md, sections 3, 4 and 9).
#
#   python3 appimg.py hex --name <name> --march <march> [--opt=<level>] <app.bin> <app.hex>
#       Completes the raw image of an app (objcopy -O binary of its ELF, linked with app.ld and
#       crt0.S): checks it, fills in the header's flags (from the -march: rv32i, rv32im,
#       rv32i_zba, rv32im_zba, rv32im_zba_zbb_zbs), name and CRC-32, rewrites <app.bin> and writes <app.hex>, the
#       file that the shell's 'load' receives: a type 04 record, data records of 16 bytes (a
#       type 04 record before every further 64 KiB), a type 05 record with the entry and the
#       end-of-file record, in upper case with CR LF line ends. Prints one line: the name, the
#       -march and --opt, the sizes, the CRC-32 and the HEX file.
#
#   python3 appimg.py info <file.hex|file.bin>
#       Reads the file as 'load' does (a .bin as the HEX file that 'hex' would write from it)
#       and prints what 'load' would answer; for an image it accepts, also the header as 'app'
#       shows it. Exit status 0 only if 'load' would accept the file.
#
#   python3 appimg.py testfiles <directory>
#       Writes the test files of the loader (SPEC.md, section 9.5): tiny.hex, the smallest
#       valid image, variations of it that 'load' must refuse, each for one reason, files
#       that hold a Ctrl-C, and files with more after the end-of-file record, which the
#       console bridge must not type into the command line.
#
# The checks and their messages are those of the loader (SPEC.md, sections 4.1 to 4.3), so a
# file can be checked here before it is sent.
# ---------------------------------------------------------------------------------------------
import argparse
import os
import struct
import sys
import tempfile
import zlib

SLOT_BASE = 0x00060000
SLOT_SIZE = 0x00020000
SLOT_END = SLOT_BASE + SLOT_SIZE
MAGIC = 0x50504148              # the bytes 'H' 'A' 'P' 'P'
ABI = 1
HEADER_SIZE = 64
NAME_SIZE = 16
STACK_MIN = 1024
NEEDS_M = 1 << 0
NEEDS_ZBA = 1 << 1
NEEDS_ZBB = 1 << 2
NEEDS_ZBS = 1 << 3
NEEDS_KNOWN = NEEDS_M | NEEDS_ZBA | NEEDS_ZBB | NEEDS_ZBS
CRC_OFFSET = 28
HEADER = struct.Struct('<IHHIIIIII16s16s')   # HadesAppHeader_t (hades_app.h)
MAX_LINE = 75                   # characters of a record without its line end: 32 data bytes
RECORD_BYTES = 16               # data bytes per record that 'hex' writes
CTRL_C = 0x03
EOF_RECORD = ':00000001FF'
MARCH_FLAGS = {'rv32i': 0, 'rv32im': NEEDS_M, 'rv32i_zba': NEEDS_ZBA, 'rv32im_zba': NEEDS_M | NEEDS_ZBA,
               'rv32im_zba_zbb_zbs': NEEDS_M | NEEDS_ZBA | NEEDS_ZBB | NEEDS_ZBS}
NAME_CHARS = frozenset(b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-')
HEX_DIGITS = frozenset(b'0123456789ABCDEFabcdef')
BAD_NAME = "bad name (1 to 15 letters, digits, '_' or '-', then NULs)"


def align16(n):
    return (n + 15) & ~15


def crc32(image):
    """The CRC-32 of an image, with the four bytes of its ulCrc32 field read as 0."""
    return zlib.crc32(bytes(image[:CRC_OFFSET]) + bytes(4) + bytes(image[CRC_OFFSET + 4:]))


def isa_name(flags):
    return 'rv32i' + ('m' if flags & NEEDS_M else '') + ''.join(
        '_' + name for bit, name in ((NEEDS_ZBA, 'zba'), (NEEDS_ZBB, 'zbb'), (NEEDS_ZBS, 'zbs')) if flags & bit)


class Header:
    def __init__(self, image):
        (self.magic, self.abi, self.header_size, self.flags, self.entry, self.size, self.bss,
         self.stack, self.crc, self.raw_name, self.reserved) = HEADER.unpack_from(bytes(image[:HEADER_SIZE]))

    @property
    def name(self):
        return self.raw_name.split(b'\0', 1)[0].decode('latin-1')

    def name_ok(self):
        text, _, rest = self.raw_name.partition(b'\0')
        return 1 <= len(text) <= NAME_SIZE - 1 and all(c in NAME_CHARS for c in text) and not any(rest)


# ------------------------------------------------------------------- the loader's rules --

def check_image(image, start):
    """The checks of an image after the end-of-file record (SPEC.md, section 4.3), in order:
    the reason 'load' gives, or None if it accepts the image."""
    n = len(image)
    if n < HEADER_SIZE:
        return f'the file holds {n} bytes, less than a 64-byte header'
    h = Header(image)
    if h.magic != MAGIC:
        return f'bad magic 0x{h.magic:08x} (an app image starts with 0x50504148, "HAPP")'
    if h.abi != ABI:
        return f'ABI version {h.abi} (this shell runs ABI version {ABI})'
    if h.header_size != HEADER_SIZE:
        return f'header size {h.header_size} ({HEADER_SIZE} expected)'
    if h.size != n:
        return f'the header says {h.size} bytes, the file holds {n}'
    if h.flags & ~NEEDS_KNOWN:
        return f'unknown flags 0x{h.flags & ~NEEDS_KNOWN:08x}'
    if not h.name_ok():
        return BAD_NAME
    if h.size % 4 or h.bss % 4:
        return 'image and bss sizes must be multiples of 4'
    if h.stack < STACK_MIN or h.stack % 16:
        return f'stack of {h.stack} bytes (at least {STACK_MIN}, a multiple of 16)'
    if not (SLOT_BASE + HEADER_SIZE <= h.entry < SLOT_BASE + h.size) or h.entry % 4:
        return (f'entry 0x{h.entry:08x} is not a word of the image after its header '
                f'(0x{SLOT_BASE + HEADER_SIZE:08x}-0x{SLOT_BASE + h.size - 1:08x})')
    copy = align16(h.size)
    total = h.size + h.bss + h.stack + copy
    if total > SLOT_SIZE:
        return (f'{h.name} needs {total} bytes of the slot (image {h.size}, bss {h.bss}, '
                f'stack {h.stack}, saved copy {copy}); the slot has {SLOT_SIZE}')
    if start is not None and start != h.entry:
        return f'the start address record says 0x{start:08x}, the entry is 0x{h.entry:08x}'
    crc = crc32(image)
    if crc != h.crc:
        return f'CRC32 mismatch: the image has 0x{crc:08x}, its header says 0x{h.crc:08x}'
    return None


def check_record(text, state):
    """The checks of a complete record line (SPEC.md, section 4.3) that follow the three made
    as its characters arrive. Applies an accepted record to state; returns the reason it is
    rejected, or None."""
    digits = text[1:]
    if len(digits) % 2 or len(digits) < 10:
        return 'malformed record'
    rec = bytes.fromhex(digits.decode('ascii'))
    length, kind, data = rec[0], rec[3], rec[4:-1]
    address = rec[1] << 8 | rec[2]
    if length != len(data):
        return f'malformed record (it announces {length} data bytes and holds {len(data)})'
    if sum(rec) & 0xFF:
        return 'checksum mismatch'
    if kind not in (0, 1, 4, 5):
        return f'record type {kind:02x} is not supported (only 00, 01, 04 and 05)'
    if kind in (1, 4, 5) and (length != {1: 0, 4: 2, 5: 4}[kind] or address != 0):
        return f'malformed type {kind:02x} record'
    if kind == 0:
        if address + length > 0x10000:
            return 'record crosses a 64 KiB boundary'
        a = state['upper'] << 16 | address
        if a < SLOT_BASE or a + length > SLOT_END:
            return f'address 0x{a:08x} is outside the app slot (0x{SLOT_BASE:08x}-0x{SLOT_END - 1:08x})'
        if a != SLOT_BASE + len(state['image']):
            return (f'address 0x{a:08x}, expected 0x{SLOT_BASE + len(state["image"]):08x} '
                    f'(data records must be contiguous, from the slot base)')
        state['image'] += data
    elif kind == 1:
        state['eof'] = True
    elif kind == 4:
        state['upper'] = data[0] << 8 | data[1]
    else:
        state['start'] = int.from_bytes(data, 'big')
    return None


def load(data):
    """What 'load' answers to the bytes of a file (SPEC.md, section 4): (line, image), where
    image is the accepted image or None. trailing is the number of bytes after the end of the
    load (they would reach the command line)."""
    state = {'upper': 0, 'image': bytearray(), 'start': None, 'eof': False}
    lines = 0                 # non-empty lines so far
    line = bytearray()        # the current line, its first MAX_LINE + 1 characters
    length = 0                # its length
    line_error = None         # the first error of its characters, as they arrive
    error = None              # the first rejected line: the reason, from then on
    for i, b in enumerate(data):
        if b == CTRL_C:   # cancels; after a rejected line the answer is that line's error
            first = error or (f'line {lines}: {line_error}' if line_error else None)
            return (f'load failed: {first}' if first else 'load cancelled'), None, len(data) - i - 1
        if b in (0x0D, 0x0A):
            if not length:
                continue      # an empty line (or the LF of CR LF)
            if error is None:
                reason = line_error or check_record(bytes(line), state)
                if reason:
                    error = f'line {lines}: {reason}'
                elif state['eof']:
                    reason = check_image(state['image'], state['start'])
                    rest = len(data) - i - 1
                    if reason:
                        return f'load failed: {reason}', None, rest
                    return accepted(state['image']), state['image'], rest
            elif length == len(EOF_RECORD) and bytes(line).upper() == EOF_RECORD.encode():
                return f'load failed: {error}', None, len(data) - i - 1
            line.clear()
            length = 0
            line_error = None
            continue
        if not length:
            lines += 1
        length += 1
        if error is None and line_error is None:
            if length == 1 and b != ord(':'):
                line_error = "a record starts with ':'"
            elif length > 1 and b not in HEX_DIGITS:
                line_error = (f"'{chr(b)}' is not a hexadecimal digit" if 0x20 <= b < 0x7F
                              else f'0x{b:02x} is not a hexadecimal digit')
            elif length > MAX_LINE:
                line_error = 'record too long (at most 32 data bytes)'
        if length <= MAX_LINE + 1:
            line.append(b)
    if not lines:
        return None, None, 0  # no record yet: line ends alone do not start the 2000-tick limit
    # The file stops before its end-of-file record: 'load' ends after 2000 ticks without input.
    return f'load failed: {error or f"line {lines}: no input for 2000 ticks (the file stopped)"}', None, 0


def accepted(image):
    h = Header(image)
    return f'loaded {h.name}: {h.size} bytes at 0x{SLOT_BASE:08x}, entry 0x{h.entry:08x}, CRC32 0x{h.crc:08x}'


def app_lines(image):
    """The output of the shell's 'app' command for an accepted image (SPEC.md, section 8.6)."""
    h = Header(image)
    copy = align16(h.size)
    return [f'name:      {h.name} (ABI {h.abi})',
            f'image:     {h.size} bytes at 0x{SLOT_BASE:08x}, entry 0x{h.entry:08x}, CRC32 0x{h.crc:08x}',
            f'isa:       {isa_name(h.flags)}',
            f'memory:    image {h.size} + bss {h.bss} + stack {h.stack} + saved copy {copy} = '
            f'{h.size + h.bss + h.stack + copy} of {SLOT_SIZE} bytes']


# ------------------------------------------------------------------------ Intel HEX --

def record(kind, address, data):
    rec = bytes([len(data), address >> 8 & 0xFF, address & 0xFF, kind]) + bytes(data)
    return ':' + (rec + bytes([-sum(rec) & 0xFF])).hex().upper()


def hex_lines(image, entry):
    """The records of an image (SPEC.md, section 9.3), without line ends."""
    out = []
    upper = None
    for offset in range(0, len(image), RECORD_BYTES):
        address = SLOT_BASE + offset
        if address >> 16 != upper:
            upper = address >> 16
            out.append(record(4, 0, upper.to_bytes(2, 'big')))
        out.append(record(0, address & 0xFFFF, image[offset:offset + RECORD_BYTES]))
    if entry is not None:
        out.append(record(5, 0, entry.to_bytes(4, 'big')))
    out.append(EOF_RECORD)
    return out


def hex_text(lines):
    return ''.join(line + '\r\n' for line in lines).encode('ascii')


def write_file(path, data):
    """Writes a file in one step (a new file renamed over the old one), so that a reader,
    such as the console bridge of a running simulation, never sees half of it."""
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=directory, prefix='.' + os.path.basename(path) + '.')
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


# ------------------------------------------------------------------------- commands --

def fail(message):
    print(f'appimg.py: {message}', file=sys.stderr)
    return 1


def cmd_hex(a):
    if a.march not in MARCH_FLAGS:
        return fail(f"unknown -march '{a.march}' (rv32i, rv32im, rv32i_zba, rv32im_zba or rv32im_zba_zbb_zbs)")
    name = a.name.encode('latin-1', 'replace')
    if not 1 <= len(name) <= NAME_SIZE - 1 or not all(c in NAME_CHARS for c in name):
        return fail(f"bad name '{a.name}' (1 to 15 letters, digits, '_' or '-')")
    with open(a.bin, 'rb') as f:
        image = bytearray(f.read())
    n = len(image)
    if n < HEADER_SIZE + 4 or n % 4:
        return fail(f'{a.bin}: the image holds {n} bytes; an image has a 64-byte header and code, '
                    f'and its size is a multiple of 4 (is it linked with app.ld and crt0.S?)')
    h = Header(image)
    # The checks of the loader that apply to the raw image (flags, name and CRC are filled in).
    image[8:12] = MARCH_FLAGS[a.march].to_bytes(4, 'little')
    image[32:48] = name.ljust(NAME_SIZE, b'\0')
    image[CRC_OFFSET:CRC_OFFSET + 4] = crc32(image).to_bytes(4, 'little')
    reason = check_image(image, None)
    if reason:
        return fail(f'{a.bin}: {reason}')
    h = Header(image)
    text = hex_text(hex_lines(image, h.entry))
    line, accepted_image, _ = load(text)            # the loader's view of the file written
    if accepted_image is None or bytes(accepted_image) != bytes(image):
        return fail(f'{a.hex}: internal error: the loader would answer: {line}')
    write_file(a.bin, bytes(image))
    write_file(a.hex, text)
    config = a.march + (f' {a.opt}' if a.opt else '')
    print(f'app {a.name} [{config}]: image {h.size} bytes, bss {h.bss}, stack {h.stack}, '
          f'CRC32 0x{h.crc:08x} -> {a.hex}')
    return 0


def cmd_info(a):
    with open(a.file, 'rb') as f:
        data = f.read()
    is_bin = a.file.endswith('.bin') or (not a.file.endswith('.hex') and not data.lstrip().startswith(b':'))
    if is_bin:   # as the file that 'hex' would write from it
        entry = Header(data.ljust(HEADER_SIZE, b'\0')).entry if len(data) >= 16 else None
        data = hex_text(hex_lines(data, entry))
    line, image, rest = load(data)
    if line is None:
        return fail(f"{a.file} holds no record: 'load' would still be waiting for a file")
    print(line)
    if image is not None:
        for l in app_lines(image):
            print(l)
    if rest and data[-rest:].strip(b'\r\n'):
        print(f"appimg.py: note: {rest} byte(s) after the end of the load; 'load' does not read them",
              file=sys.stderr)
    return 0 if image is not None else 1


# The test files of the loader (SPEC.md, section 9.5): tiny.hex and its variations.
TINY_CODE = (0x00700513).to_bytes(4, 'little') + (0x00008067).to_bytes(4, 'little')   # li a0, 7; ret


def tiny_image(magic=b'HAPP', abi=ABI, flags=0, entry=SLOT_BASE + HEADER_SIZE, size=None,
               stack=STACK_MIN, name=b'tiny', code=TINY_CODE, crc=None):
    size = HEADER_SIZE + len(code) if size is None else size
    image = bytearray(HEADER.pack(int.from_bytes(magic, 'little'), abi, HEADER_SIZE, flags, entry, size,
                                  0, stack, 0, name.ljust(NAME_SIZE, b'\0'), bytes(16)) + code)
    image[CRC_OFFSET:CRC_OFFSET + 4] = (crc32(image) if crc is None else crc).to_bytes(4, 'little')
    return image


def tiny_lines(**changes):
    image = tiny_image(**changes)
    return hex_lines(image, SLOT_BASE + HEADER_SIZE)


def rerecord(line, change):
    """A record line with its bytes changed by change(bytearray of length, address, type,
    data) and the checksum recomputed."""
    rec = bytearray(bytes.fromhex(line[1:-2]))
    change(rec)
    return ':' + (bytes(rec) + bytes([-sum(rec) & 0xFF])).hex().upper()


def replace(lines, number, text):
    out = list(lines)
    out[number - 1] = text
    return out


def test_files():
    """{file name: contents} of the test files, and the answer of 'load' to each."""
    tiny = tiny_lines()
    crc = Header(tiny_image()).crc

    def set_length(rec):
        rec[0] = 9

    def extend(rec):
        rec.extend(bytes(33 - rec[0]))
        rec[0] = 33

    files = {
        'tiny.hex': hex_text(tiny),
        'bad-colon.hex': hex_text(replace(tiny, 2, tiny[1][1:])),
        'bad-char.hex': hex_text(replace(tiny, 4, tiny[3][:9] + 'G' + tiny[3][10:])),
        'bad-checksum.hex': hex_text(replace(tiny, 3, tiny[2][:-2] + f'{(int(tiny[2][-2:], 16) + 1) & 0xFF:02X}')),
        'bad-length.hex': hex_text(replace(tiny, 6, rerecord(tiny[5], set_length))),
        'bad-long.hex': hex_text(replace(tiny, 6, rerecord(tiny[5], extend))),
        'bad-type.hex': hex_text(replace(tiny, 1, ':020000020006F6')),
        'bad-address.hex': hex_text(replace(tiny, 1, ':020000040005F5')),
        'bad-gap.hex': hex_text(tiny[:3] + tiny[4:]),
        'bad-magic.hex': hex_text(tiny_lines(magic=b'XAPP')),
        'bad-abi.hex': hex_text(tiny_lines(abi=2)),
        'bad-imagesize.hex': hex_text(tiny_lines(size=76)),
        'bad-flags.hex': hex_text(tiny_lines(flags=0x80)),
        'bad-name.hex': hex_text(tiny_lines(name=b'ti ny')),
        'bad-entry.hex': hex_text(tiny_lines(entry=0x00060048)),
        'bad-size.hex': hex_text(tiny_lines(stack=0x00020000)),
        'bad-start.hex': hex_text(replace(tiny, 7, ':0400000500060044AD')),
        'bad-crc.hex': hex_text(tiny_lines(code=(0x00800513).to_bytes(4, 'little') + TINY_CODE[4:], crc=crc)),
        'cancel.hex': hex_text(tiny[:3]) + bytes([CTRL_C]),
        'cancel-mid.hex': hex_text(tiny[:3]) + tiny[3][:9].encode() + bytes([CTRL_C]) +
                          tiny[3][9:].encode() + b'\r\n' + hex_text(tiny[4:]),
        'bad-cancel.hex': hex_text(replace(tiny, 2, tiny[1][1:])[:3]) + bytes([CTRL_C]) + hex_text(tiny[3:]),
        'ok-blank.hex': hex_text(tiny[:3]) + b'\r\n' + hex_text(tiny[3:]) + b'\r\n\r\n',
        'after-eof.hex': hex_text(tiny) + hex_text(tiny[1:3]) + b'\r\n',
    }
    return files


def cmd_testfiles(a):
    os.makedirs(a.directory, exist_ok=True)
    for name, data in test_files().items():
        write_file(os.path.join(a.directory, name), data)
    return 0


def main():
    ap = argparse.ArgumentParser(description='The image tool of the HaDes-V+ app SDK '
                                             '(test/freertos/loader/SPEC.md).')
    sub = ap.add_subparsers(dest='cmd', required=True)
    h = sub.add_parser('hex', help='complete a raw image and write its Intel HEX file')
    h.add_argument('--name', required=True)
    h.add_argument('--march', required=True)
    h.add_argument('--opt', default='')
    h.add_argument('bin')
    h.add_argument('hex')
    i = sub.add_parser('info', help="what 'load' answers to a file")
    i.add_argument('file')
    t = sub.add_parser('testfiles', help='write the test files of the loader')
    t.add_argument('directory')
    a = ap.parse_args()
    try:
        return {'hex': cmd_hex, 'info': cmd_info, 'testfiles': cmd_testfiles}[a.cmd](a)
    except OSError as e:
        return fail(f'{e.filename}: {e.strerror}')


if __name__ == '__main__':
    sys.exit(main())
