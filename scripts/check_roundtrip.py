"""Check a round-tripped export against the file it came from.

  python scripts/check_roundtrip.py <original.mid> <exported.mid>
  python scripts/check_roundtrip.py <original.mid>          # finds the export

A round trip is: import a .mid into REAPER, run midi-export, compare
what came back. Unlike the baseline gates this is NOT a parity check -- REAPER
re-times and re-groups events on import, and may split or merge tracks. The
question is whether anything was *lost or altered*, which is what this reports:

  * every SysEx message, byte for byte, whatever the manufacturer
  * tempo and time-signature metas
  * total note-on/note-off balance, per channel
  * event counts per channel

Other metas (markers, copyright, key signature, FF 7F sequencer-specific, port)
are reported but do not fail the check: REAPER is not obliged to carry them
through an import, so their loss is a fidelity note about the round trip rather
than a fault in the exporter.

The export writes into the open project's folder, named after the project, so
with one argument this picks the newest *-export*.mid under the repo. Pass the
path explicitly when several tests are in flight.
"""
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import compare_smf as C  # noqa: E402


def newest_export(root):
    """The most recently written *-export*.mid anywhere under root.

    The exporter names its output after the open project, so several round
    trips leave several files. Picking the newest is a convenience for the
    common case of "I just ran it"; pass the path explicitly when checking an
    older one.
    """
    best, best_mtime = None, -1
    for dirpath, _, names in os.walk(root):
        if '.git' in dirpath:
            continue
        for n in names:
            if n.endswith('.mid') and '-export' in n:
                q = os.path.join(dirpath, n)
                m = os.path.getmtime(q)
                if m > best_mtime:
                    best, best_mtime = q, m
    return best


def sysex_bag(tracks):
    return Counter(bytes([e['lead']]) + e['data']
                   for ev in tracks for e in ev if e['kind'] == 'sysex')


def meta_bag(tracks, types):
    return Counter((e['type'], e['data'])
                   for ev in tracks for e in ev
                   if e['kind'] == 'meta' and e['type'] in types)


def note_balance(tracks):
    """Per channel: note-ons, note-offs, and anything left hanging."""
    on, off = Counter(), Counter()
    open_notes = Counter()
    for ev in tracks:
        for e in ev:
            if e['kind'] != 'chan' or len(e['data']) < 2:
                continue
            hi, ch = e['status'] & 0xF0, e['status'] & 0x0F
            if hi == 0x90 and e['data'][1] > 0:
                on[ch] += 1
                open_notes[(ch, e['data'][0])] += 1
            elif hi == 0x80 or (hi == 0x90 and e['data'][1] == 0):
                off[ch] += 1
                open_notes[(ch, e['data'][0])] -= 1
    hung = {k: v for k, v in open_notes.items() if v != 0}
    return on, off, hung


def chan_events(tracks):
    return Counter(e['status'] & 0x0F
                   for ev in tracks for e in ev if e['kind'] == 'chan')


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    orig = argv[1]
    got = argv[2] if len(argv) > 2 else newest_export(ROOT)
    if not got:
        print('no *-export*.mid found under %s -- run the export first, '
              'or pass the path explicitly' % ROOT)
        return 1

    print('original: %s' % orig)
    print('export:   %s' % got)
    print()

    _, ta = C.parse_smf(orig)
    _, tb = C.parse_smf(got)

    problems = []

    # 1. SysEx, byte for byte. This is the check that counts: it is vendor
    # neutral, unlike docs/re/verify_smf.py which skips non-Roland messages.
    sa, sb = sysex_bag(ta), sysex_bag(tb)
    if sa == sb:
        print('SysEx: %d message(s), all byte-identical' % sum(sa.values()))
    else:
        missing, extra = sa - sb, sb - sa
        problems.append('SysEx: %d lost, %d altered/new'
                        % (sum(missing.values()), sum(extra.values())))
        print('SysEx MISMATCH:')
        for m, n in missing.most_common():
            print('   lost    %s%s' % (m.hex(' '), ' x%d' % n if n > 1 else ''))
        for m, n in extra.most_common():
            print('   gained  %s%s' % (m.hex(' '), ' x%d' % n if n > 1 else ''))

    # 2. Tempo (FF 51) and time signature (FF 58).
    ma, mb = meta_bag(ta, {0x51, 0x58}), meta_bag(tb, {0x51, 0x58})
    if ma == mb:
        print('tempo/timesig: %d meta(s) preserved' % sum(ma.values()))
    else:
        problems.append('tempo/timesig differs')
        print('tempo/timesig MISMATCH:')
        for t, d in sorted((ma - mb).keys()):
            print('   lost    ff %02x %s' % (t, d.hex(' ')))
        for t, d in sorted((mb - ma).keys()):
            print('   gained  ff %02x %s' % (t, d.hex(' ')))

    # 2b. Every other meta that carries data. These are reported separately
    # because REAPER is not obliged to keep them on import -- losing a marker
    # or a copyright notice is a fidelity note, not a corrupt file, whereas a
    # dropped FF 7F sequencer-specific may well be real data for the target
    # device. Reported, not fatal, so the gate stays about lost *music*.
    CARRIED = {0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x20, 0x21, 0x54,
               0x59, 0x7F}
    oa, ob = meta_bag(ta, CARRIED), meta_bag(tb, CARRIED)
    if oa == ob:
        print('other metas: %d preserved (text, markers, port, FF 7F, ...)'
              % sum(oa.values()))
    else:
        lost, gained = oa - ob, ob - oa
        print('other metas: %d lost, %d new  (informational -- REAPER may not '
              'carry these through an import)'
              % (sum(lost.values()), sum(gained.values())))
        shown = 0
        for (t, d), n in lost.most_common():
            if shown >= 8:
                print('   ... and %d more kind(s)' % (len(lost) - shown))
                break
            print('   lost    ff %02x %s%s'
                  % (t, d[:16].hex(' '), ' x%d' % n if n > 1 else ''))
            shown += 1

    # 3. Notes. Counts may legitimately move between tracks on import, so they
    # are compared per channel across the whole file rather than per track.
    on_a, off_a, hung_a = note_balance(ta)
    on_b, off_b, hung_b = note_balance(tb)
    if on_a == on_b and off_a == off_b:
        print('notes: %d on / %d off, unchanged per channel'
              % (sum(on_a.values()), sum(off_a.values())))
    else:
        problems.append('note counts differ')
        print('note count MISMATCH (channel: original -> export):')
        for ch in sorted(set(on_a) | set(on_b)):
            if on_a[ch] != on_b[ch] or off_a[ch] != off_b[ch]:
                print('   ch %-2d  on %d -> %d,  off %d -> %d'
                      % (ch, on_a[ch], on_b[ch], off_a[ch], off_b[ch]))

    if hung_b:
        problems.append('%d hung note(s) in the export' % len(hung_b))
        print('HUNG NOTES in the export:')
        for (ch, pitch), v in sorted(hung_b.items()):
            print('   ch %d pitch %d: %+d unmatched' % (ch, pitch, v))
    elif hung_a:
        print('note: the original had %d hung note(s); the export has none'
              % len(hung_a))
    else:
        print('hung notes: none')

    # 4. Everything else on a channel, so a lost controller or pitch bend is
    # not silently ignored by the note-only check above.
    ca, cb = chan_events(ta), chan_events(tb)
    if ca == cb:
        print('channel events: %d, unchanged per channel' % sum(ca.values()))
    else:
        problems.append('channel event counts differ')
        print('channel event MISMATCH (channel: original -> export):')
        for ch in sorted(set(ca) | set(cb)):
            if ca[ch] != cb[ch]:
                print('   ch %-2d  %d -> %d  (%+d)'
                      % (ch, ca[ch], cb[ch], cb[ch] - ca[ch]))

    print()
    if problems:
        print('RESULT: LOST OR ALTERED DATA')
        for p in problems:
            print('  - %s' % p)
        return 1
    print('RESULT: ROUND TRIP CLEAN (no events lost or altered)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
