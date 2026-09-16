"""Generate docs/midi-tests/torture.mid -- everything the real fixtures miss.

  python scripts/make_torture.py

The fixtures in docs/midi-tests/ are all well-behaved music, so whole code
paths in the exporter have never run on real data. This file is deliberately
nasty, and every case in it is one a correct SMF reader must handle.

Surveyed against the existing fixtures, these were never exercised:

  * A0 poly aftertouch      -- the only channel status no fixture contains
  * FF 00 sequence number   -- and FF 04/05/07/54, all absent
  * F7 escape events        -- exactly one exists, in a file REAPER
                               would not import
  * multi-packet SysEx      -- an F0 not ending in F7, continued by F7
                               packets. The plan marks this a known ceiling
  * running status          -- no fixture uses it; REAPER never writes it
  * a large delta-time      -- forcing a 3- and 4-byte varlen
  * all 16 channels at once -- fixtures use at most 16 across many tracks
  * an empty track          -- name and end-of-track only
  * simultaneous events     -- many on one tick, where sort stability shows
  * extreme velocities/values -- 1 and 127 at the boundaries
  * a note held across the whole file -- the hung-note detector's live case

Deliberately NOT included: a malformed file. Everything here is legal SMF, so
a failure means the exporter is wrong, never that the fixture is.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), 'docs', 'midi-tests', 'torture.mid')

PPQN = 960
BAR = PPQN * 4


def varlen(n):
    out = bytes([n & 0x7F])
    n >>= 7
    while n:
        out = bytes([(n & 0x7F) | 0x80]) + out
        n >>= 7
    return out


def chunk(cid, data):
    return cid + struct.pack('>I', len(data)) + data


def meta(mtype, payload):
    return b'\xff' + bytes([mtype]) + varlen(len(payload)) + payload


def sysex(payload, lead=0xF0):
    return bytes([lead]) + varlen(len(payload)) + payload


class Track:
    """Accumulates events at absolute ticks, emits a delta-encoded MTrk."""

    def __init__(self, name=None):
        self.events = []
        if name is not None:
            self.at(0, meta(0x03, name.encode('latin-1')))

    def at(self, tick, raw):
        self.events.append((tick, len(self.events), raw))
        return self

    def build(self):
        body = b''
        prev = 0
        for tick, _, raw in sorted(self.events, key=lambda e: (e[0], e[1])):
            body += varlen(tick - prev) + raw
            prev = tick
        body += varlen(0) + meta(0x2F, b'')
        return chunk(b'MTrk', body)


def conductor():
    """Tempo map with changes, odd time signatures, and the rarely-seen metas."""
    t = Track('torture')
    # FF 00 sequence number, absent from every existing fixture.
    t.at(0, meta(0x00, b'\x00\x01'))
    t.at(0, meta(0x01, b'torture fixture: every edge case at once'))
    t.at(0, meta(0x02, b'(c) PAGER test suite'))
    # FF 54 SMPTE offset -- 1 hour, 0 min, 0 sec, 0 frame, 0 subframe.
    t.at(0, meta(0x54, b'\x01\x00\x00\x00\x00'))
    t.at(0, meta(0x58, bytes([4, 2, 24, 8])))      # 4/4
    t.at(0, meta(0x51, struct.pack('>I', 500000)[1:]))   # 120 BPM

    # Tempo changes, including extremes a synth must still follow.
    t.at(BAR, meta(0x51, struct.pack('>I', 250000)[1:]))     # 240 BPM
    t.at(BAR, meta(0x58, bytes([7, 3, 24, 8])))              # 7/8
    t.at(BAR * 2, meta(0x51, struct.pack('>I', 2000000)[1:]))  # 30 BPM
    t.at(BAR * 2, meta(0x58, bytes([5, 2, 24, 8])))          # 5/4
    t.at(BAR * 3, meta(0x51, struct.pack('>I', 100000)[1:]))   # 600 BPM
    t.at(BAR * 3, meta(0x58, bytes([3, 3, 24, 8])))          # 3/8
    t.at(BAR * 4, meta(0x51, struct.pack('>I', 500000)[1:]))   # back to 120
    t.at(BAR * 4, meta(0x58, bytes([4, 2, 24, 8])))

    t.at(BAR, meta(0x06, b'tempo 240'))            # markers
    t.at(BAR * 2, meta(0x06, b'tempo 30'))
    t.at(BAR * 3, meta(0x06, b'tempo 600'))
    t.at(0, meta(0x59, b'\xfd\x01'))               # key sig: 3 flats, minor
    return t


def all_statuses():
    """Every channel message type, including the A0 no fixture has."""
    t = Track('all statuses')
    tick = 0
    t.at(tick, b'\xb0\x00\x00')                    # bank select MSB
    t.at(tick, b'\xb0\x20\x00')                    # bank select LSB
    t.at(tick, b'\xc0\x00')                        # program change (2 bytes)
    tick += 240
    t.at(tick, b'\x90\x3c\x40')                    # note on
    t.at(tick + 120, b'\xa0\x3c\x40')              # POLY AFTERTOUCH -- the gap
    t.at(tick + 180, b'\xa0\x3c\x7f')
    t.at(tick + 240, b'\xd0\x40')                  # channel pressure (2 bytes)
    t.at(tick + 300, b'\xe0\x00\x40')              # pitch bend centre
    t.at(tick + 360, b'\xe0\x00\x00')              # pitch bend min
    t.at(tick + 420, b'\xe0\x7f\x7f')              # pitch bend max
    t.at(tick + 480, b'\x80\x3c\x40')              # note off
    # Boundary values: velocity 1 and 127, note 0 and 127.
    t.at(tick + 600, b'\x90\x00\x01')
    t.at(tick + 720, b'\x80\x00\x00')
    t.at(tick + 840, b'\x90\x7f\x7f')
    t.at(tick + 960, b'\x80\x7f\x7f')
    return t


def all_channels():
    """All 16 channels on one track, several events landing on one tick."""
    t = Track('16 channels')
    for ch in range(16):
        t.at(0, bytes([0xC0 | ch, ch]))            # program per channel
    # 16 note-ons on the SAME tick: this is where an unstable sort shows up.
    for ch in range(16):
        t.at(BAR, bytes([0x90 | ch, 60 + ch, 100]))
    for ch in range(16):
        t.at(BAR + 480, bytes([0x80 | ch, 60 + ch, 64]))
    return t


def sysex_torture():
    """SysEx shapes that are legal but rare: escapes, multi-packet, long."""
    t = Track('sysex')
    # Six manufacturers, as in multivendor.mid.
    for i, payload in enumerate([
        b'\x43\x10\x4c\x00\x00\x7e\x00',           # Yamaha XG
        b'\x42\x30\x00\x01',                       # Korg
        b'\x41\x10\x42\x12\x40\x00\x7f\x00\x41',   # Roland GS reset
        b'\x7e\x7f\x09\x01',                       # Universal GM on
        b'\x00\x00\x0e\x00\x00',                   # Alesis, 3-byte id
        b'\x40\x00\x20\x00\x0a',                   # Kawai
    ]):
        t.at(i * 120, sysex(payload + b'\xf7'))

    # An F7 escape event: bytes transmitted with no leading F0. Exactly one
    # exists in all the real fixtures, in a file REAPER would not import.
    t.at(BAR, sysex(b'\x01\x02\x03', lead=0xF7))

    # MULTI-PACKET SysEx: an F0 whose payload does NOT end in F7, continued by
    # F7 packets. The spec allows it; the plan records it as a known ceiling
    # because no fixture had one. Now one does.
    t.at(BAR * 2, sysex(b'\x41\x10\x42\x12\x40\x00'))          # no F7: opens
    t.at(BAR * 2 + 240, sysex(b'\x7f\x00', lead=0xF7))         # continues
    t.at(BAR * 2 + 480, sysex(b'\x41\xf7', lead=0xF7))         # closes

    # A long payload, forcing a two-byte varlen length (>= 128 bytes).
    t.at(BAR * 3, sysex(b'\x41\x10\x42\x12' + bytes(200) + b'\xf7'))
    return t


def big_deltas():
    """Delta-times large enough to need 3- and 4-byte varlens."""
    t = Track('big deltas')
    t.at(0, b'\x90\x40\x40')
    t.at(0 + 240, b'\x80\x40\x40')
    # 0x100000 ticks = 3-byte varlen; 0x200000 = 4-byte.
    t.at(0x100000, b'\x91\x41\x40')
    t.at(0x100000 + 240, b'\x81\x41\x40')
    t.at(0x200000, b'\x92\x42\x40')
    t.at(0x200000 + 240, b'\x82\x42\x40')
    return t


def running_status():
    """A track packed with running status, which no fixture uses.

    Built by hand because Track.build() always writes an explicit status.
    """
    body = varlen(0) + meta(0x03, b'running status')
    body += varlen(0) + b'\x90\x30\x40'        # explicit status once
    for i in range(1, 32):                     # then data bytes alone
        body += varlen(60) + bytes([0x30 + (i % 12), 0x40])
    body += varlen(60) + b'\xb0\x07\x64'       # a controller resets it
    for i in range(8):
        body += varlen(30) + bytes([0x0a, 0x40])
    # Silence everything this track opened.
    body += varlen(0) + b'\x90\x30\x00'
    for i in range(1, 32):
        body += varlen(0) + bytes([0x30 + (i % 12), 0x00])
    body += varlen(0) + meta(0x2F, b'')
    return chunk(b'MTrk', body)


def empty_track():
    """Name and end-of-track, nothing else. A track with no events at all."""
    return Track('empty').build()


def dense():
    """Many events on the same tick, and a note held across the whole file."""
    t = Track('dense')
    # A note that opens at tick 0 and never closes until the very end -- the
    # hung-note detector's live case, and what a loop crop must not produce.
    t.at(0, b'\x93\x24\x7f')
    # 64 controller events on ONE tick.
    for i in range(64):
        t.at(BAR, bytes([0xB3, i % 120, i % 128]))
    # A dense CC sweep, the shape a pitch-bend automation lane produces.
    for i in range(128):
        t.at(BAR * 2 + i * 8, bytes([0xE3, i, i]))
    t.at(BAR * 5, b'\x83\x24\x40')             # finally closes
    return t


def main():
    tracks = [conductor(), all_statuses(), all_channels(), sysex_torture(),
              big_deltas(), dense()]
    built = [t.build() for t in tracks]
    built.append(running_status())
    built.append(empty_track())

    data = chunk(b'MThd', struct.pack('>HHH', 1, len(built), PPQN))
    data += b''.join(built)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, 'wb').write(data)
    print('wrote %s (%d bytes, %d tracks)' % (OUT, len(data), len(built)))

    # Read it back and report what it actually contains, so the file is never
    # trusted on the strength of the code that wrote it.
    sys.path.insert(0, HERE)
    import compare_smf as C
    (fmt, ntrk, div), parsed = C.parse_smf(OUT)
    print('parses: format %d, %d tracks, %d PPQN' % (fmt, ntrk, div))

    from collections import Counter
    st, mt = Counter(), Counter()
    esc = multi = 0
    for ev in parsed:
        for e in ev:
            if e['kind'] == 'chan':
                st[e['status'] & 0xF0] += 1
            elif e['kind'] == 'meta':
                mt[e['type']] += 1
            elif e['kind'] == 'sysex':
                if e['lead'] == 0xF7:
                    esc += 1
                elif not e['data'].endswith(b'\xf7'):
                    multi += 1
    print('  channel statuses: %s'
          % ' '.join('%02x' % k for k in sorted(st)))
    print('  meta types:       %s'
          % ' '.join('%02x' % k for k in sorted(mt)))
    print('  F7 escapes: %d,  unterminated F0 (multi-packet): %d' % (esc, multi))

    for want, label in [(0xA0, 'A0 poly aftertouch'), (0xC0, 'C0 program'),
                        (0xD0, 'D0 channel pressure')]:
        assert st.get(want), 'missing ' + label
    for want in (0x00, 0x04, 0x54, 0x59):
        if not mt.get(want):
            print('  note: FF %02X not present' % want)
    assert esc >= 1, 'no F7 escape written'
    assert multi >= 1, 'no multi-packet SysEx written'

    chans = {e['status'] & 0x0F for ev in parsed for e in ev
             if e['kind'] == 'chan'}
    print('  channels used: %d of 16' % len(chans))

    on = sum(1 for ev in parsed for e in ev if e['kind'] == 'chan'
             and (e['status'] & 0xF0) == 0x90 and e['data'][1] > 0)
    off = sum(1 for ev in parsed for e in ev if e['kind'] == 'chan'
              and ((e['status'] & 0xF0) == 0x80
                   or ((e['status'] & 0xF0) == 0x90 and e['data'][1] == 0)))
    print('  notes: %d on / %d off %s'
          % (on, off, '(balanced)' if on == off else '(IMBALANCED)'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
