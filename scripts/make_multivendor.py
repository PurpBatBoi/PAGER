"""Generate docs/multivendor.mid -- a SysEx fixture that is not all Roland.

  python scripts/make_multivendor.py

The three GS fixtures in docs/ are every one of them Roland, so every SysEx
gate in the plan is a Roland gate without this file. The failure it guards
against is silent: an exporter that special-cased manufacturer 0x41, or
recomputed a checksum by Roland's rule, would still produce a file that opens
and looks right while carrying wrong bytes for everyone else.

docs/re/verify_smf.py cannot catch that -- it skips non-Roland messages
unchecked. scripts/compare_smf.py compares SysEx byte for byte regardless of
vendor, which is why it, not verify_smf.py, is the SysEx gate.

Six manufacturers, each a real message shape rather than invented bytes:

  43  Yamaha       XG System On
  42  Korg         device inquiry-style write
  41  Roland       GS Reset (checksum 0x41, the one the repo already asserts)
  7E  Universal    non-realtime GM System On
  00 00 0E  Alesis three-byte manufacturer id, which is the case a naive
                   parser that assumes one id byte gets wrong
  40  Kawai        a short parameter write

The Alesis entry earns its place: three-byte ids start with a 0x00 that a
length-guessing reader will misread, and nothing else in docs/ has one.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), 'docs', 'multivendor.mid')

PPQN = 960

MESSAGES = [
    ('Yamaha XG System On',   bytes.fromhex('43 10 4C 00 00 7E 00')),
    ('Korg write',            bytes.fromhex('42 30 00 01')),
    ('Roland GS Reset',       bytes.fromhex('41 10 42 12 40 00 7F 00 41')),
    ('Universal GM System On', bytes.fromhex('7E 7F 09 01')),
    ('Alesis (3-byte id)',    bytes.fromhex('00 00 0E 00 00')),
    ('Kawai parameter',       bytes.fromhex('40 00 20 00 0A')),
]


def varlen(n):
    out = bytes([n & 0x7F])
    n >>= 7
    while n:
        out = bytes([(n & 0x7F) | 0x80]) + out
        n >>= 7
    return out


def chunk(cid, data):
    return cid + struct.pack('>I', len(data)) + data


def main():
    # Conductor: 4/4 at 120 BPM, matching the other fixtures in docs/.
    conductor = (varlen(0) + b'\xff\x03' + varlen(len(b'multivendor')) + b'multivendor'
                 + varlen(0) + b'\xff\x58\x04\x04\x02\x18\x08'
                 + varlen(0) + b'\xff\x51\x03\x07\xa1\x20'
                 + varlen(0) + b'\xff\x2f\x00')

    body = varlen(0) + b'\xff\x03' + varlen(len(b'SysEx')) + b'SysEx'
    tick = 0
    for i, (_, payload) in enumerate(MESSAGES):
        delta = 0 if i == 0 else PPQN      # one per beat after the first
        tick += delta
        # F0 <varlen length> <payload> F7 -- the length counts the trailing F7
        # but not the leading F0.
        full = payload + b'\xf7'
        body += varlen(delta) + b'\xf0' + varlen(len(full)) + full
    # One note, so the file is a plausible piece of music rather than a blob,
    # and so the hung-note detector has something balanced to look at.
    body += varlen(PPQN) + b'\x90\x3c\x40'
    body += varlen(PPQN) + b'\x80\x3c\x40'
    body += varlen(0) + b'\xff\x2f\x00'

    data = (chunk(b'MThd', struct.pack('>HHH', 1, 2, PPQN))
            + chunk(b'MTrk', conductor)
            + chunk(b'MTrk', body))

    open(OUT, 'wb').write(data)
    print('wrote %s (%d bytes, %d SysEx messages)'
          % (OUT, len(data), len(MESSAGES)))

    # Prove the file reads back as intended before anything depends on it.
    sys.path.insert(0, HERE)
    import compare_smf as C
    _, tracks = C.parse_smf(OUT)
    got = [e for ev in tracks for e in ev if e['kind'] == 'sysex']
    assert len(got) == len(MESSAGES), (
        'expected %d SysEx events, parsed %d' % (len(MESSAGES), len(got)))
    for (name, payload), e in zip(MESSAGES, got):
        want = payload + b'\xf7'
        assert e['data'] == want, (
            '%s: wrote %s, parsed %s'
            % (name, want.hex(' '), e['data'].hex(' ')))
        print('  ok  %-24s f0 %s' % (name, e['data'].hex(' ')))
    return 0


if __name__ == '__main__':
    sys.exit(main())
