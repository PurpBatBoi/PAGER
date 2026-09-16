"""Compare two Standard MIDI Files semantically, or summarise one.

  python scripts/compare_smf.py <a.mid> <b.mid>    parity check
  python scripts/compare_smf.py <file.mid>         per-track summary

This is the gate for the export script: it answers "does our file play the
same as REAPER's?" rather than "is it the same bytes?". Those differ, and the
difference matters -- an SMF has several legal encodings of identical music,
and a byte comparison would fail on all of them.

Normalised away (does not change playback):

  * running status -- 90 3c 40 / 3e 40 is the same music as 90 3c 40 / 90 3e 40
  * note-off spelling -- 9n vel 0 is a note-off, same as 8n
  * event order within a single tick
  * track order, and the track lengths implied by it

Compared (does change playback):

  * every event's absolute tick, status, channel and data bytes
  * SysEx payloads, byte for byte, whatever the manufacturer
  * tempo and time-signature metas
  * which named track each event belongs to

SysEx is compared as opaque bytes with no vendor knowledge, which is what makes
this the SysEx gate rather than docs/re/verify_smf.py -- that one validates
Roland checksums and addresses but skips every other manufacturer unchecked.

Self-test:  python scripts/compare_smf.py --self-test
"""
import math
import os
import struct
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
def _find(name):
    """Locate a fixture under docs/, wherever it has been filed."""
    for d in (os.path.join(ROOT, 'docs', 'midi-tests'),
              os.path.join(ROOT, 'docs')):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    return os.path.join(ROOT, 'docs', name)


BASELINE = _find('[native]16-chs-baseline.mid')

# Meta types whose payload we compare. Others are carried but reported
# separately, because a differing FF 01 text does not change what plays.
META_TEXT = 0x01
META_NAME = 0x03
META_PORT = 0x21
META_END = 0x2F
META_TEMPO = 0x51
META_TIMESIG = 0x58


def read_varlen(d, p):
    v = 0
    while True:
        b = d[p]
        p += 1
        v = (v << 7) | (b & 0x7F)
        if not b & 0x80:
            return v, p


def parse_smf(path):
    """Parse an SMF into (header, tracks).

    header is (format, ntracks, division); tracks is a list of event lists,
    each event a dict with tick, kind and the bytes that matter for that kind.

    The event walk follows docs/re/verify_smf.py, which is already proven
    against these files -- including running status, which REAPER does not emit
    but third-party files do.
    """
    d = open(path, 'rb').read()
    if d[:4] != b'MThd':
        raise ValueError('%s: not an SMF (no MThd)' % path)
    hdr_len = struct.unpack('>I', d[4:8])[0]
    fmt, ntrk, div = struct.unpack('>HHH', d[8:14])
    p = 8 + hdr_len

    tracks = []
    for _ in range(ntrk):
        if d[p:p + 4] != b'MTrk':
            break
        length = struct.unpack('>I', d[p + 4:p + 8])[0]
        end = p + 8 + length
        q = p + 8
        tick = 0
        status = 0
        events = []
        while q < end:
            delta, q = read_varlen(d, q)
            tick += delta
            b = d[q]

            if b == 0xFF:                             # meta
                mtype = d[q + 1]
                q += 2
                n, q = read_varlen(d, q)
                data = bytes(d[q:q + n])
                q += n
                events.append({'tick': tick, 'kind': 'meta',
                               'type': mtype, 'data': data})

            elif b in (0xF0, 0xF7):                   # sysex, or escape
                lead = b
                q += 1
                n, q = read_varlen(d, q)
                body = bytes(d[q:q + n])
                q += n
                # Kept whole and unparsed. No manufacturer byte is inspected,
                # so a Yamaha or Kawai message is compared as strictly as a
                # Roland one.
                events.append({'tick': tick, 'kind': 'sysex',
                               'lead': lead, 'data': body})

            else:                                     # channel / system
                if b & 0x80:
                    status = b
                    q += 1
                elif status == 0:
                    raise ValueError('%s: running status with no prior status '
                                     'at byte %d' % (path, q))
                hi = status & 0xF0
                if hi in (0xC0, 0xD0):
                    nd = 1
                elif hi == 0xF0:
                    nd = {0xF1: 1, 0xF2: 2, 0xF3: 1}.get(status, 0)
                else:
                    nd = 2
                data = bytes(d[q:q + nd])
                q += nd
                events.append({'tick': tick, 'kind': 'chan',
                               'status': status, 'data': data})
        tracks.append(events)
        p = end
    return (fmt, ntrk, div), tracks


def track_name(events):
    for e in events:
        if e['kind'] == 'meta' and e['type'] == META_NAME:
            return e['data'].decode('latin-1')
    return None


def normalise(e):
    """Reduce one event to what actually affects playback.

    Note-off spelling is folded here: a 9n with velocity 0 is a note-off, and
    REAPER writes 8n where another tool writes 9n vel 0. Both silence the note,
    so comparing them as different events would report false failures.
    """
    if e['kind'] == 'chan':
        status, data = e['status'], e['data']
        if status & 0xF0 == 0x90 and len(data) == 2 and data[1] == 0:
            status = 0x80 | (status & 0x0F)
            data = bytes([data[0], 64])       # canonical release velocity
        return ('chan', status, data)
    if e['kind'] == 'sysex':
        return ('sysex', e['lead'], e['data'])
    return ('meta', e['type'], e['data'])


def describe(key):
    kind = key[0]
    if kind == 'chan':
        return '%02x %s' % (key[1], key[2].hex(' '))
    if kind == 'sysex':
        return '%02x %s' % (key[1], key[2].hex(' '))
    return 'ff %02x %s' % (key[1], key[2].hex(' '))


def bag(events, skip_name=False):
    """Multiset of (tick, normalised event), so order within a tick is free.

    A Counter rather than a set: two identical events on the same tick are
    two events, and losing one of them is a real difference.
    """
    c = Counter()
    for e in events:
        if skip_name and e['kind'] == 'meta' and e['type'] == META_NAME:
            continue
        # End-of-track is structural, not musical -- every track has exactly
        # one and its tick follows the track length.
        if e['kind'] == 'meta' and e['type'] == META_END:
            continue
        c[(e['tick'], normalise(e))] += 1
    return c


def playable_count(events):
    """Events that carry music: channel messages and SysEx.

    The plan's figures are in these terms -- "track 'A01' 1105 events" is 1,105
    channel messages, not the metas alongside them -- so the summary lines use
    the same denominator and stay comparable with it.
    """
    return sum(1 for e in events if e['kind'] in ('chan', 'sysex'))


def hung_notes(events):
    """Note-ons with no matching note-off, per (channel, pitch).

    This is the loop-crop failure mode: a note that straddles a cropped repeat
    needs an explicit note-off at the boundary, or the file ends with the note
    still sounding.
    """
    open_notes = defaultdict(int)
    for e in events:
        if e['kind'] != 'chan':
            continue
        status, data = e['status'], e['data']
        hi, ch = status & 0xF0, status & 0x0F
        if len(data) < 2:
            continue
        if hi == 0x90 and data[1] > 0:
            open_notes[(ch, data[0])] += 1
        elif hi == 0x80 or (hi == 0x90 and data[1] == 0):
            open_notes[(ch, data[0])] -= 1
    return {k: v for k, v in open_notes.items() if v != 0}


def channels(events):
    return sorted({e['status'] & 0x0F for e in events if e['kind'] == 'chan'})


def match_tracks(ta, tb):
    """Pair up tracks between two files.

    Track 0 is matched positionally as <conductor>: the spec requires the tempo
    map to be the first MTrk, and its FF 03 is the sequence name, which follows
    the filename. Matching it by name would report a false mismatch on every
    comparison between two differently-named exports.

    The rest match by name, which survives REAPER reordering tracks on import.
    """
    pairs, used_b = [], set()
    if ta and tb:
        pairs.append(('<conductor>', 0, 0))
        used_b.add(0)

    names_b = {}
    for i, ev in enumerate(tb):
        if i == 0:
            continue
        names_b.setdefault(track_name(ev) or '<unnamed %d>' % i, []).append(i)

    for i, ev in enumerate(ta):
        if i == 0:
            continue
        name = track_name(ev) or '<unnamed %d>' % i
        cand = names_b.get(name)
        if cand:
            j = cand.pop(0)
            used_b.add(j)
            pairs.append((name, i, j))
        else:
            pairs.append((name, i, None))

    for j, ev in enumerate(tb):
        if j in used_b or j == 0:
            continue
        pairs.append((track_name(ev) or '<unnamed %d>' % j, None, j))
    return pairs


def compare(path_a, path_b, limit=6, out=print):
    (fa, _, da), ta = parse_smf(path_a)
    (fb, _, db), tb = parse_smf(path_b)

    problems = []
    out('A: %s' % path_a)
    out('B: %s' % path_b)
    out('')

    # A different PPQN is a different encoding of the same music, not different
    # music: 480 and 960 express the same beat, one with twice the resolution.
    # Both sides are scaled to their LCM so ticks become comparable. The scale
    # factors are exact integers, so an event that is genuinely on the wrong
    # beat still fails -- nothing is rounded into agreement.
    #
    # Only PPQN divisions are scaled. A negative division is SMPTE (frames per
    # second), where the unit is time rather than beats and the two are not
    # interchangeable.
    if da != db and da > 0 and db > 0:
        lcm = da * db // math.gcd(da, db)
        sa, sb = lcm // da, lcm // db
        for trk in ta:
            for ev in trk:
                ev['tick'] *= sa
        for trk in tb:
            for ev in trk:
                ev['tick'] *= sb
        out('note: division %d vs %d -- ticks scaled to %d for comparison'
            % (da, db, lcm))
    elif da != db:
        problems.append('division differs: %d vs %d' % (da, db))
        out('DIVISION MISMATCH: %d vs %d -- ticks are not comparable' % (da, db))
    if fa != fb:
        out('note: format %d vs %d (informational)' % (fa, fb))
    if len(ta) != len(tb):
        out('note: %d tracks vs %d' % (len(ta), len(tb)))

    # The sequence name follows the filename, so it is reported but never
    # counts as a failure.
    na, nb = track_name(ta[0]) if ta else None, track_name(tb[0]) if tb else None
    if na != nb:
        out('note: sequence name %r vs %r (informational)' % (na, nb))
    out('')

    for name, i, j in match_tracks(ta, tb):
        if i is None:
            problems.append('track %r only in B' % name)
            out('track %-16r ONLY IN B (%d events)' % (name, len(tb[j])))
            continue
        if j is None:
            problems.append('track %r only in A' % name)
            out('track %-16r ONLY IN A (%d events)' % (name, len(ta[i])))
            continue

        # The conductor's own name is the filename, so it is excluded from the
        # comparison for track 0 only.
        skip_name = (name == '<conductor>')
        ca, cb = bag(ta[i], skip_name), bag(tb[j], skip_name)
        if ca == cb:
            out('track %-16r %d events ok' % (name, playable_count(ta[i])))
            continue

        missing = ca - cb
        extra = cb - ca
        problems.append('track %r: %d missing, %d extra'
                        % (name, sum(missing.values()), sum(extra.values())))
        out('track %-16r MISMATCH: %d missing, %d extra'
            % (name, sum(missing.values()), sum(extra.values())))
        for (tick, key), n in list(missing.most_common(limit)):
            out('    missing t=%-8d %s%s' % (tick, describe(key),
                                             ' x%d' % n if n > 1 else ''))
        for (tick, key), n in list(extra.most_common(limit)):
            out('    extra   t=%-8d %s%s' % (tick, describe(key),
                                             ' x%d' % n if n > 1 else ''))
        if sum(missing.values()) > limit or sum(extra.values()) > limit:
            out('    ... (showing first %d of each)' % limit)

    out('')
    if problems:
        out('RESULT: MISMATCH (%d)' % len(problems))
        for p in problems:
            out('  - %s' % p)
        return 1
    out('RESULT: PARITY')
    return 0


def summarise(path, out=print):
    (fmt, ntrk, div), tracks = parse_smf(path)
    out('%s' % path)
    out('format %d, %d tracks, %d PPQN' % (fmt, ntrk, div))
    out('')
    total_hung = 0
    for i, ev in enumerate(tracks):
        name = track_name(ev) or ('<conductor>' if i == 0 else '<unnamed>')
        sysex = sum(1 for e in ev if e['kind'] == 'sysex')
        chans = channels(ev)
        hung = hung_notes(ev)
        total_hung += len(hung)
        bits = ['%4d events' % len(ev)]
        if chans:
            bits.append('ch %s' % ','.join(str(c) for c in chans))
        if sysex:
            bits.append('%d sysex' % sysex)
        out('track %2d %-16r %s' % (i, name, '  '.join(bits)))
        for (ch, pitch), n in sorted(hung.items()):
            out('    HUNG NOTE ch%d pitch %d: %+d unmatched' % (ch, pitch, n))
    out('')
    if total_hung:
        out('HUNG NOTES: %d (note on/off imbalance)' % total_hung)
        return 1
    out('no hung notes')
    return 0


# ----------------------------------------------------------------- self-test

def _rewrite_running_status(data):
    """Re-encode every track using running status, changing no music.

    The harness must tolerate this: it is a legal and much smaller encoding of
    the identical file, and a comparison that failed on it would be useless.
    """
    out = bytearray(data[:14])
    p = 14
    ntrk = struct.unpack('>H', data[10:12])[0]
    for _ in range(ntrk):
        length = struct.unpack('>I', data[p + 4:p + 8])[0]
        end = p + 8 + length
        q = p + 8
        body = bytearray()
        status = 0
        last_written = 0
        while q < end:
            start = q
            _, q = read_varlen(data, q)
            delta = data[start:q]
            b = data[q]
            if b == 0xFF:
                q += 2
                n, after = read_varlen(data, q)
                q = after + n
                body += delta + data[start + len(delta):q]
                last_written = 0            # meta resets running status
                status = 0
            elif b in (0xF0, 0xF7):
                q += 1
                n, after = read_varlen(data, q)
                q = after + n
                body += delta + data[start + len(delta):q]
                last_written = 0
                status = 0
            else:
                if b & 0x80:
                    status = b
                    q += 1
                hi = status & 0xF0
                nd = 1 if hi in (0xC0, 0xD0) else 2
                payload = data[q:q + nd]
                q += nd
                body += delta
                if status != last_written:
                    body += bytes([status])
                    last_written = status
                body += payload
        out += b'MTrk' + struct.pack('>I', len(body)) + body
        p = end
    return bytes(out)


def _find_nth_note_on(data, n=1):
    """Byte offset of the velocity byte of the nth note-on, for mutation."""
    p = 14
    ntrk = struct.unpack('>H', data[10:12])[0]
    seen = 0
    for _ in range(ntrk):
        length = struct.unpack('>I', data[p + 4:p + 8])[0]
        end = p + 8 + length
        q = p + 8
        status = 0
        while q < end:
            _, q = read_varlen(data, q)
            b = data[q]
            if b == 0xFF:
                q += 2
                nn, q = read_varlen(data, q)
                q += nn
            elif b in (0xF0, 0xF7):
                q += 1
                nn, q = read_varlen(data, q)
                q += nn
            else:
                if b & 0x80:
                    status = b
                    q += 1
                hi = status & 0xF0
                nd = 1 if hi in (0xC0, 0xD0) else 2
                if hi == 0x90 and data[q + 1] > 0:
                    seen += 1
                    if seen == n:
                        return q + 1
                q += nd
        p = end
    return None


def self_test():
    """The four checks the plan names, plus the ones that guard against a
    harness that passes everything."""
    import tempfile

    if not os.path.exists(BASELINE):
        print('self-test needs %s' % BASELINE)
        return 1

    raw = open(BASELINE, 'rb').read()
    tmp = tempfile.mkdtemp(prefix='compare_smf_')
    quiet = lambda *a, **k: None
    failures = []

    def check(desc, got, want):
        if got == want:
            print('  ok: %s' % desc)
        else:
            print('  FAIL: %s (got %r, want %r)' % (desc, got, want))
            failures.append(desc)

    def write(name, data):
        p = os.path.join(tmp, name)
        open(p, 'wb').write(data)
        return p

    print('compare_smf.py self-test, against %s' % os.path.basename(BASELINE))

    # 1. A file is at parity with itself. If this fails nothing else means
    #    anything.
    check('baseline vs itself is PARITY',
          compare(BASELINE, BASELINE, out=quiet), 0)

    # 2. One velocity byte among 6,441 events is caught.
    off = _find_nth_note_on(raw, 1)
    assert off is not None, 'no note-on found in baseline'
    mutated = bytearray(raw)
    mutated[off] = 1 if mutated[off] != 1 else 2
    check('one changed velocity byte is caught',
          compare(BASELINE, write('vel.mid', bytes(mutated)), out=quiet), 1)

    # 3. A tempo change is caught. 120 BPM (07 a1 20) -> 150 (06 1a 80).
    assert raw.count(b'\xff\x51\x03\x07\xa1\x20') == 1
    check('a changed tempo is caught',
          compare(BASELINE,
                  write('tempo.mid', raw.replace(b'\xff\x51\x03\x07\xa1\x20',
                                                 b'\xff\x51\x03\x06\x1a\x80')),
                  out=quiet), 1)

    # 4. The same music written with running status is NOT a failure. This is
    #    the check that stops the harness being a byte comparison in disguise.
    rs = _rewrite_running_status(raw)
    check('running-status rewrite is smaller', len(rs) < len(raw), True)
    check('running-status rewrite is tolerated',
          compare(BASELINE, write('rs.mid', rs), out=quiet), 0)

    # 5. 9n vel 0 note-offs compare equal to 8n. REAPER writes 8n; other tools
    #    write 9n vel 0; they are the same music.
    a = (b'MThd\x00\x00\x00\x06\x00\x01\x00\x01\x03\xc0'
         b'MTrk\x00\x00\x00\x0c'
         b'\x00\x90\x3c\x40' b'\x87\x40\x80\x3c\x40' b'\x00\xff\x2f\x00')
    b = (b'MThd\x00\x00\x00\x06\x00\x01\x00\x01\x03\xc0'
         b'MTrk\x00\x00\x00\x0c'
         b'\x00\x90\x3c\x40' b'\x87\x40\x90\x3c\x00' b'\x00\xff\x2f\x00')
    check('8n and 9n-vel-0 note-offs compare equal',
          compare(write('off8.mid', a), write('off9.mid', b), out=quiet), 0)

    # 6. A SysEx payload differing by one byte is caught, for a NON-Roland
    #    manufacturer. This is the case verify_smf.py cannot see, and the whole
    #    reason this tool is the SysEx gate.
    def sysex_file(payload):
        trk = b'\x00' + payload + b'\x00\xff\x2f\x00'
        return (b'MThd\x00\x00\x00\x06\x00\x01\x00\x01\x03\xc0' +
                b'MTrk' + struct.pack('>I', len(trk)) + trk)
    xg_ok = b'\xf0\x08\x43\x10\x4c\x00\x00\x7e\x00\xf7'
    xg_bad = b'\xf0\x08\x43\x10\x4c\x00\x00\x7f\x00\xf7'
    check('a one-byte Yamaha SysEx change is caught',
          compare(write('xg1.mid', sysex_file(xg_ok)),
                  write('xg2.mid', sysex_file(xg_bad)), out=quiet), 1)

    # 7. A dropped event is caught even when everything else matches -- the
    #    failure mode where an exporter silently loses one message.
    two = sysex_file(xg_ok + b'\x00' + b'\xf0\x05\x7e\x7f\x09\x01\xf7')
    check('a dropped SysEx event is caught',
          compare(write('two.mid', two),
                  write('one.mid', sysex_file(xg_ok)), out=quiet), 1)

    # 8. Mutations of the real baseline, each a way an exporter can go wrong.
    #    These matter more than the synthetic files above: they run against
    #    6,441 real events, where a weak comparison would drown one bad byte.
    note_off = _find_nth_note_on(raw, 1)

    shifted = bytearray(raw)                       # event lands on a wrong tick
    i = raw.find(b'\x90', note_off + 50)
    shifted[i - 1] = (shifted[i - 1] + 1) & 0x7F
    check('a shifted delta-time is caught',
          compare(BASELINE, write('tick.mid', bytes(shifted)), out=quiet), 1)

    rechan = bytearray(raw)                        # right note, wrong channel
    rechan[note_off - 2] = 0x91
    check('an event on the wrong channel is caught',
          compare(BASELINE, write('chan.mid', bytes(rechan)), out=quiet), 1)

    hdr = bytearray(raw[:14])                      # a whole track disappears
    struct.pack_into('>H', hdr, 10, 11)
    p, kept = 14, b''
    for k in range(12):
        ln = struct.unpack('>I', raw[p + 4:p + 8])[0]
        if k != 11:
            kept += raw[p:p + 8 + ln]
        p += 8 + ln
    check('a dropped track is caught',
          compare(BASELINE, write('drop.mid', bytes(hdr) + kept), out=quiet), 1)

    div = bytearray(raw)                           # ticks stop being comparable
    struct.pack_into('>H', div, 12, 480)
    check('a changed division is caught',
          compare(BASELINE, write('div.mid', bytes(div)), out=quiet), 1)

    sx = bytearray(raw)                            # Roland GS reset, one byte
    j = raw.find(b'\xf0\x41\x10\x42\x12\x40\x00\x7f')
    sx[j + 6] = 0x01
    check('a changed Roland SysEx byte is caught',
          compare(BASELINE, write('sysex.mid', bytes(sx)), out=quiet), 1)

    # 9. The hung-note detector fires on an unmatched note-on, and stays quiet
    #    on a balanced file.
    hung = (b'MThd\x00\x00\x00\x06\x00\x01\x00\x01\x03\xc0'
            b'MTrk\x00\x00\x00\x08' b'\x00\x90\x3c\x40' b'\x00\xff\x2f\x00')
    check('hung note detected', summarise(write('hung.mid', hung), out=quiet), 1)
    check('balanced file reports none', summarise(BASELINE, out=quiet), 0)

    print('')
    if failures:
        print('%d SELF-TEST FAILURE(S)' % len(failures))
        return 1
    print('self-test passed')
    return 0


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    if '--self-test' in argv:
        return self_test()
    if len(args) == 2:
        return compare(args[0], args[1])
    if len(args) == 1:
        return summarise(args[0])
    print(__doc__)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
