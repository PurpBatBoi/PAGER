"""Extract one track's MIDI buffer from a .rpp, in MIDI_GetAllEvts shape.

  python scripts/rpp_to_evts.py <project.rpp> <track name> <out.bin>

Lets the export path be exercised without REAPER: the .rpp stores every event
of a MIDI take as `E <delta> <b1> <b2> <b3>`, which is the same information
MIDI_GetAllEvts hands a script, just in text. Pack it the way REAPER packs it
-- {int32 offset, char flag, int32 msglen, byte msg[]} -- and the real
take_events/build_smf run against real project data.

This is a development aid for the phase 3/4 gates, not part of the export.
"""
import base64
import io
import re
import struct
import sys

EVENT = re.compile(r'^([Ee])\s+(\d+)\s+((?:[0-9a-fA-F]{2}\s*)+)$')
# SysEx and text metas are stored as a <X delta flag ...> block whose body is
# base64 of the whole raw message (F0..F7, or FF <type> <data>).
XOPEN = re.compile(r'^<[Xx]\s+(\d+)\s+(\d+)')


def item_blocks(block):
    """Split a track into its <ITEM> blocks.

    Each item is a separate take at run time, and the exporter walks them
    separately -- so anything testing it has to as well, or per-item behaviour
    (REAPER's item-end All Notes Off, loop expansion) is modelled wrong.
    """
    parts = block.split('\n    <ITEM')
    return parts[1:] if len(parts) > 1 else [block]


def track_block(src, name):
    """The text of one <TRACK>, found by its NAME line."""
    i = src.find('NAME ' + name + '\n')
    if i < 0:
        i = src.find('NAME "' + name + '"')
    if i < 0:
        raise SystemExit('no track named %r in the project' % name)
    j = src.find('\n  <TRACK', i)
    return src[i:j if j > 0 else len(src)]


def events(block):
    """Yield (kind, delta, raw message) in file order.

    Both encodings appear in a MIDI take and both matter: `E` lines carry
    channel messages, and `<X>` blocks carry SysEx and text metas -- which is
    where the baseline's GS reset lives.
    """
    lines = block.split('\n')
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        m = EVENT.match(s)
        if m:
            yield m.group(1), int(m.group(2)), bytes.fromhex(
                m.group(3).replace(' ', ''))
            i += 1
            continue
        x = XOPEN.match(s)
        if x:
            body = []
            i += 1
            while i < len(lines) and lines[i].strip() != '>':
                body.append(lines[i].strip())
                i += 1
            i += 1                      # step past the closing '>'
            # REAPER wraps a long body and pads every line on its own, so a
            # continuation line can follow a '=='. Joining first is invalid
            # base64; each line has to be decoded separately.
            raw = b''.join(base64.b64decode(l) for l in body if l)
            if raw:
                yield 'X', int(x.group(1)), raw
            continue
        i += 1


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 1
    src = io.open(argv[1], encoding='utf-8', errors='replace').read()
    # `Track#2` selects the second item; plain `Track` means the first.
    name, _, which = argv[2].partition('#')
    blocks = item_blocks(track_block(src, name))
    idx = int(which) - 1 if which else 0
    if idx >= len(blocks):
        raise SystemExit('%s has %d item(s), asked for #%s'
                         % (name, len(blocks), which or '1'))
    blocks = [blocks[idx]]

    buf = bytearray()
    n = 0
    ticks = 0
    for kind, delta, msg in events(blocks[0]):
        # flag bit 1 is "selected" in REAPER's buffer; lowercase means selected
        # in the .rpp. Nothing downstream reads it, but keep it faithful.
        buf += struct.pack('<iBi', delta, 1 if kind.islower() else 0, len(msg))
        buf += msg
        n += 1
        ticks += delta
    open(argv[3], 'wb').write(bytes(buf))
    print('%s: %d events, %d ticks (%.1f QN), %d bytes'
          % (argv[2], n, ticks, ticks / 960.0, len(buf)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
