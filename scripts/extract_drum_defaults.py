"""Extract the factory drum-setup defaults to editor/drum_defaults.lua.

  python scripts/extract_drum_defaults.py

The SC-8850 holds a full set of drum-setup parameters for every note of every
factory drum kit, in all four of its instrument maps, and they are NOT
uniform: Concert Snare ships with Reverb 50 while MC-500 Beep 1 ships with
Reverb 0 and Pitch +12, and the hi-hats share an Assign Group so they cut each
other off. Seeding the Part Editor's drum panel with one flat guess would
misreport every one of those.

Sources are the GSAE decompilation in docs/gsae-decomp/data/, themselves
extracted from the original editor's .def tables (see docs/gsae-decomp/NOTES.md,
P2):

  Drum8850.json   Bank LSB 4 -- the SC-8850 map
  DRUM.json       Bank LSB 1, 2, 3 -- the SC-55, SC-88 and SC-88Pro maps

A kit is identified by (Bank LSB, program change). The LSB is what selects the
instrument map, so the same program change means a different kit in each --
and the editor already tracks it, because selecting a voice from another map
moves the Part to that map.

Those notes' field order was left as "TBD" by NOTES.md. It is resolved here,
and asserted below rather than assumed.

FIELD ORDER -- all nine parameters, in GSAE's own column order:

  idx 0  PLAY NOTE NUMBER   pitch, stored with 60 as neutral (see below)
  idx 1  TVA LEVEL          0..127
  idx 2  ASSIGN GROUP       0 = Non, 1..127 = a mutual-cut group
  idx 3  PANPOT             0 = Random, 1..64..127 = left..centre..right
  idx 4  REVERB SEND        0..127
  idx 5  CHORUS SEND        0..127
  idx 6  Rx. NOTE OFF       0..1
  idx 7  Rx. NOTE ON        0..1
  idx 8  DELAY SEND         0..127; 0 throughout the factory kits
  idx 9..11                 NOT data -- the stale-name garbage NOTES.md
                            documents for the name field, which is why they
                            hold values above 127

What settled it was GSAE's own Drum Window, which draws these nine columns in
exactly this order: Pitch | Level | Assign G | Panpot | Reverb | Chorus |
Rx.Note | Rx.Note | Delay. A screenshot of it against SC-55 STANDARD matches
bytes 0..8 of every row, one for one.

Three further checks, because a column order that merely looks plausible is
the failure mode here:

  1. Against the hardware panel. Sound Canvas VA, SC-8850 STANDARD 1: note 24
     "Concert Snr" reads Pitch 0, Level 120, Pan C, Reverb 50, Assign Group
     Non; note 22 "MC-500 Beep" reads Pitch 12, Level 107, Reverb 0. Both
     match these columns exactly, and both were then confirmed in the Part
     Editor itself against the same panel.
  2. Against musical sense. idx 2 groups the three hi-hats (notes 42/44/46)
     together and the two triangles (80/81) together, in every ordinary drum
     kit of every map -- which is what an Assign Group is for. idx 6 is 1 only
     on SUSTAINED sounds (applause, snare rolls, whistles, footsteps, car
     engines) and 0 on every percussive hit, which is exactly when a drum
     instrument needs Note Off; idx 7 is 1 on every note of every kit, as
     Rx Note On must be for an instrument to sound at all.
  3. Against the manual's own field list (SC-8850 OM p.163): "Set, Pitch
     Coarse, Inst Level, Inst Pan, Reverb Send, Chorus Send, Delay Send,
     Assign Group, Rx NoteOn, Rx Note Off". The manual's prose order differs
     from the stored record order, which is why 1. and 2. are the checks that
     settle it rather than this one.

PITCH is the one field whose stored form is not its wire form. The manual
calls 41 m1 rr an absolute "PLAY NOTE NUMBER", 00..7F. The tables store 60 for
the large majority of notes and the panel shows 0 for those, so the stored
byte is relative to a neutral 60: the toms (LowTom/MidTom/HiTom) all store 53,
and the hi/low agogos store 63/58 -- one sample, offset per instrument. This
script keeps the RAW stored byte, because that is what the hardware address
takes; drum_params.lua is what subtracts 60 when it seeds a note.

DELAY SEND is idx 8, and is 0 for every note of every factory kit in all four
maps. That is a real value rather than a gap -- GSAE's window shows the same
zeros -- so it is extracted like any other column instead of being assumed.

CHORUS SEND is idx 5. It is non-zero throughout the SC-55 map, where it
commonly tracks the Reverb value, and zero throughout the SC-88, SC-88Pro and
SC-8850 maps -- GSAE's window shows the same zeros on STANDARD 1 of all three.

KIT NAMES come from the editor's own .reabank files rather than from
DRUM_kits.json. That JSON is a bare ordered list which does NOT line up with
the sparse program changes -- pairing them naively names SC-55 program change
0 "USERDRUM 0" when it is STANDARD. The .reabank states number and name
together, and is the file the editor already ships.

USER DRUM SLOTS are skipped. SC-88 and SC-88Pro program changes 64 and 65 are
User Drum Sets: the table holds 128 placeholder "USERDRUMINST" notes for each,
which are empty slots rather than factory values.

ODD RECORDS are kept exactly as GSAE holds them. SC-8850 JUNGLE (pc 10) notes
105..114 read as shifted by one byte -- note 105 carries Rx Note Off 12, notes
106..113 have Pitch 0 / Rx Note On 0, note 114 has Pitch 0 -- and GAMELAN 2
(pc 55) note 73 has Rx Note On 0. GSAE's own Drum Window shows these same
values, and GSAE is the authority here, so they are extracted verbatim rather
than repaired or dropped. GSAE_WINDOW_ODD pins them.
"""
import json, os, sys, collections

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, 'docs', 'gsae-decomp', 'data')
OUT = os.path.join(ROOT, 'editor', 'drum_defaults.lua')

# Bank LSB -> (source json, the .reabank the editor ships for that map).
# The LSB is the map selector, and the GSAE `bank` field carries the same
# number, which is what lets the two be matched at all.
MAPS = [
    (1, 'DRUM.json', 'SC-55-Drums.reabank', 'SC-55'),
    (2, 'DRUM.json', 'SC-88-Drums.reabank', 'SC-88'),
    (3, 'DRUM.json', 'SC-88Pro-Drums.reabank', 'SC-88Pro'),
    (4, 'Drum8850.json', 'SC-8850-Drums.reabank', 'SC-8850'),
]

# Column -> the drum_params.lua id it feeds.
#
# The stored order IS the order GSAE's own Drum Window draws its columns, which
# is what identified it: Pitch, Level, Assign G, Panpot, Reverb, Chorus,
# Rx.Note (off), Rx.Note (on), Delay. All nine parameters are here -- the
# record carries twelve bytes and the last three are the stale-name garbage
# NOTES.md documents for the name field, not data.
COLUMNS = [
    (0, 'pitch'),
    (1, 'level'),
    (2, 'assign_group'),
    (3, 'pan'),
    (4, 'reverb'),
    (5, 'chorus'),
    (6, 'rx_note_off'),
    (7, 'rx_note_on'),
    (8, 'delay'),
]

# The neutral stored value for PLAY NOTE NUMBER. Named because drum_params.lua
# subtracts the same number to produce the relative pitch the panel shows.
PITCH_NEUTRAL = 60

# Program changes that are user slots rather than factory kits.
USER_SLOTS = {64, 65}

# The ordinary drum kits of each map -- the ones whose notes 42/44/46 really
# are hi-hats. The specialised kits reuse those notes for unrelated sounds
# (ORCHESTRA has timpani, VOICE has vocal samples, GAMELAN has gongs), so they
# are excluded from the grouping check rather than expected to satisfy it.
HAT_KITS = {
    1: [0, 8, 16, 24, 25, 32, 40],
    2: [0, 1, 8, 16, 24, 25, 26, 32, 40],
    3: [0, 1, 2, 8, 9, 10, 11, 16, 24, 25, 26, 27, 28, 29, 30, 32, 40],
    4: [0, 1, 2, 8, 9, 10, 11, 12, 13, 16,
        24, 25, 26, 27, 28, 29, 30, 32, 33, 40, 41, 42],
}


def load(name):
    with open(os.path.join(DATA, name), encoding='utf-8') as f:
        return json.load(f)


def reabank(name):
    """The kits one .reabank declares, as {pc: name}."""
    out = {}
    path = os.path.join(ROOT, 'editor', name)
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(';') or line.startswith('Bank'):
                continue
            num, _, label = line.partition(' ')
            if num.isdigit():
                out[int(num)] = label.strip()
    if not out:
        sys.exit('no kits found in ' + name)
    return out


def clean(records, lsb):
    """One map's usable records: right bank, real kit."""
    return [r for r in records
            if r['bank'] == lsb and r['pc'] not in USER_SLOTS]


def check_fields(by_key, lsb, label):
    """Assert the recovered field order still holds for one map."""
    # The hi-hats must share one non-zero assign group in every ordinary drum
    # kit -- the property that identifies the column at all.
    for pc in HAT_KITS[lsb]:
        hats = [by_key.get((pc, n)) for n in (42, 44, 46)]
        if not all(hats):
            sys.exit('%s kit %d is missing a hi-hat' % (label, pc))
        groups = {h[2] for h in hats}
        if len(groups) != 1 or 0 in groups:
            sys.exit('%s kit %d does not group its hi-hats: %s'
                     % (label, pc, sorted(groups)))

    # Every shipped value must be a 7-bit byte. The Rx switches are not held to
    # 0..1: JUNGLE note 105 stores Rx Note Off 12, as GSAE does, and the panel
    # reads any non-zero switch as On.
    for (pc, note), row in by_key.items():
        for i, (_, name) in enumerate(COLUMNS):
            v = row[i]
            if not (0 <= v <= 127):
                sys.exit('%s kit %d note %d: %s=%d out of 0..127'
                         % (label, pc, note, name, v))


# Rows read off GSAE's own Drum Window, SC-55 STANDARD (bank LSB 1, pc 0), in
# its column order: pitch, level, assign group, panpot, reverb, chorus,
# rx note off, rx note on, delay.
#
# This is the fixture that pins the COLUMN ORDER itself. Every other check
# here tests one column's plausibility; these rows test all nine at once
# against a screenshot of the application that owns the data, which is the
# only external oracle short of the hardware.
GSAE_WINDOW_SC55 = {
    27: (60, 79, 0, 49, 127, 127, 0, 1, 0),   # High Q
    28: (60, 107, 0, 49, 127, 127, 0, 1, 0),  # Slap
    29: (60, 87, 7, 54, 63, 63, 0, 1, 0),     # Scr.Push
    30: (60, 91, 7, 54, 63, 63, 0, 1, 0),     # Scr.Pull
    31: (60, 115, 0, 64, 63, 63, 0, 1, 0),    # Sticks
    32: (60, 127, 0, 54, 0, 0, 0, 1, 0),      # Sq.Click
    35: (60, 127, 0, 64, 32, 32, 0, 1, 0),    # Kick 2
    36: (60, 127, 0, 64, 32, 32, 0, 1, 0),    # Kick 1
    41: (48, 127, 0, 34, 127, 127, 0, 1, 0),  # LowTom 2  -- pitch below neutral
    42: (60, 123, 1, 84, 31, 31, 0, 1, 0),    # Closd HH  -- assign group 1
    43: (52, 127, 0, 46, 127, 127, 0, 1, 0),  # LowTom 1
    44: (60, 87, 1, 84, 32, 32, 0, 1, 0),     # Pedal HH
    45: (55, 127, 0, 58, 127, 127, 0, 1, 0),  # MidTom 2
    46: (60, 119, 1, 84, 31, 31, 0, 1, 0),    # Open HH
    49: (60, 127, 0, 84, 127, 127, 0, 1, 0),  # CrshCym1
    55: (69, 83, 0, 54, 127, 127, 0, 1, 0),   # SplshCym  -- pitch above neutral
    63: (65, 107, 0, 39, 127, 127, 0, 1, 0),  # OH Conga
    67: (65, 99, 0, 29, 100, 100, 0, 1, 0),   # Hi.Agogo
}


# The same window, SC-55 ROOM (pc 8). A second kit, because one kit can only
# prove the column ORDER -- two prove that the per-kit lookup reaches the right
# row as well. ROOM shares most of its percussion with STANDARD but replaces
# every tom (R.LTom/R.MTom/R.HTom, pitched 36..76), which is exactly where a
# kit mix-up would show.
GSAE_WINDOW_SC55_ROOM = {
    39: (60, 99, 0, 54, 127, 127, 0, 1, 0),   # HandClap
    41: (36, 127, 0, 34, 127, 127, 0, 1, 0),  # R.LTom 2 -- room tom, not STANDARD's
    43: (44, 127, 0, 46, 127, 127, 0, 1, 0),  # R.LTom 1
    45: (52, 127, 0, 58, 127, 127, 0, 1, 0),  # R.MTom 2
    47: (60, 127, 0, 70, 127, 127, 0, 1, 0),  # R.MTom 1
    48: (68, 127, 0, 82, 127, 127, 0, 1, 0),  # R.HTom 2
    50: (76, 127, 0, 94, 127, 127, 0, 1, 0),  # R.HTom 1
    59: (61, 120, 0, 34, 127, 127, 0, 1, 0),  # RideCym2 -- pan differs from STANDARD
    69: (60, 95, 0, 29, 63, 63, 0, 1, 0),     # Cabasa
}


# GSAE's window on the SC-8850 records that look shifted, (pc, note) -> row.
# Kept verbatim on purpose -- see ODD RECORDS above. A regeneration that
# repaired or dropped them would fail here.
GSAE_WINDOW_ODD = {
    (10, 104): (60, 127, 0, 64, 20, 0, 1, 1, 0),     # JUNGLE Phono Nz -- last normal
    (10, 105): (60, 106, 0, 64, 64, 0, 12, 0, 1),    # Power S1
    (10, 106): (0, 60, 115, 0, 64, 64, 0, 0, 1),     # Dance S1
    (10, 113): (0, 60, 127, 0, 64, 127, 0, 0, 1),    # 707 S1
    (10, 114): (0, 110, 0, 64, 64, 0, 0, 1, 0),      # 808 S2
    (10, 115): (60, 110, 0, 64, 64, 0, 0, 1, 0),     # 808 S1 -- normal again
    (55, 72): (75, 127, 0, 94, 127, 0, 0, 1, 0),     # GAMELAN 2 Pemade
    (55, 73): (78, 127, 0, 94, 127, 0, 0, 0, 0),     # Pemade -- Rx Note On 0
}


def check_anchors(maps):
    """Everything the column order is held against, byte for byte.

    Transcribed from screenshots rather than derived from the data they check:
    an expectation built by reading the same bytes would agree with a wrong
    column order perfectly.
    """
    # Sound Canvas VA, SC-8850 STANDARD 1 -- two notes, read off the panel.
    ANCHORS = [
        (4, 0, 24, dict(pitch=60, level=120, assign_group=0, pan=64, reverb=50)),
        (4, 0, 22, dict(pitch=72, level=107, assign_group=0, pan=64, reverb=0)),
    ]
    for lsb, pc, note, want in ANCHORS:
        row = maps.get(lsb, {}).get((pc, note))
        if not row:
            sys.exit('missing verification anchor lsb=%d pc=%d note=%d'
                     % (lsb, pc, note))
        for i, (_, name) in enumerate(COLUMNS):
            if name in want and row[i] != want[name]:
                sys.exit('anchor lsb=%d pc=%d note=%d: %s is %d, panel shows %d'
                         % (lsb, pc, note, name, row[i], want[name]))

    # GSAE's Drum Window -- all nine columns at once, on two kits.
    rows = 0
    for pc, kit, fixture in ((0, 'STANDARD', GSAE_WINDOW_SC55),
                             (8, 'ROOM', GSAE_WINDOW_SC55_ROOM)):
        for note, want in sorted(fixture.items()):
            row = maps.get(1, {}).get((pc, note))
            if not row:
                sys.exit('SC-55 %s note %d missing' % (kit, note))
            if len(row) != len(want):
                sys.exit('note %d: %d columns extracted, the window shows %d'
                         % (note, len(row), len(want)))
            for i, (_, name) in enumerate(COLUMNS):
                if row[i] != want[i]:
                    sys.exit('SC-55 %s note %d: %s is %d, the GSAE window '
                             'shows %d -- the column order or the per-kit '
                             'lookup is wrong'
                             % (kit, note, name, row[i], want[i]))
            rows += 1

    for (pc, note), want in sorted(GSAE_WINDOW_ODD.items()):
        row = maps[4].get((pc, note))
        if tuple(row or ()) != want:
            sys.exit('SC-8850 kit %d note %d is %s, the GSAE window shows %s'
                     % (pc, note, row, list(want)))
        rows += 1

    # The two kits must actually DIFFER where the window says they do, or the
    # per-kit lookup could be returning one kit for both and still pass above.
    for note in (41, 43, 45, 48, 50):
        std = maps[1].get((0, note))
        room = maps[1].get((8, note))
        if std and room and std[0] == room[0]:
            sys.exit('SC-55 note %d has the same pitch in STANDARD and ROOM; '
                     'the per-kit lookup is not distinguishing them' % note)
    return rows


def lua_str(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'") + "'"


def main():
    sources = {}
    maps, names = {}, {}

    for lsb, src, bank_file, label in MAPS:
        if src not in sources:
            sources[src] = load(src)
        records = clean(sources[src], lsb)
        if not records:
            sys.exit('no records for %s (bank LSB %d)' % (label, lsb))

        by_key = {(r['pc'], r['note']):
                  [r['params'][i] for i, _ in COLUMNS] for r in records}
        check_fields(by_key, lsb, label)
        maps[lsb] = by_key

        # Names come from the .reabank, which states number and name together.
        bank = reabank(bank_file)
        kits = sorted({pc for pc, _ in by_key})
        missing = [pc for pc in kits if pc not in bank]
        if missing:
            sys.exit('%s: %s names kits %s that %s does not'
                     % (label, src, missing, bank_file))
        names[lsb] = {pc: bank[pc] for pc in kits}

    window_rows = check_anchors(maps)

    ids = [name for _, name in COLUMNS]
    out = []
    w = out.append
    w('-- Factory drum-setup defaults for all four instrument maps.')
    w('-- GENERATED -- do not edit.')
    w('--')
    w('--   python scripts/extract_drum_defaults.py')
    w('--')
    w('-- One entry per note of every factory drum kit, extracted from the GSAE')
    w('-- decompilation and verified against the hardware panel. See the')
    w('-- extractor for how the field order was recovered and what it is checked')
    w('-- against; that comment is the real documentation for this data.')
    w('--')
    w('-- A kit is (Bank LSB, program change). The LSB selects the instrument')
    w('-- map -- 1 = SC-55, 2 = SC-88, 3 = SC-88Pro, 4 = SC-8850 -- so the same')
    w('-- program change is a different kit in each.')
    w('--')
    w('-- Values are the RAW stored bytes. Pitch is relative to %d (the neutral'
      % PITCH_NEUTRAL)
    w('-- PLAY NOTE NUMBER), and Pan runs 0=Random, 1..64..127=L..C..R, so both')
    w('-- are converted where they are read rather than here.')
    w('--')
    w('-- Rows are GSAE\'s bytes verbatim, including the few that look shifted')
    w('-- (SC-8850 JUNGLE 105..114, GAMELAN 2 note 73). User Drum Sets are not')
    w('-- factory data and are not included.')
    w('')
    w('local M = {}')
    w('')
    w('-- The neutral stored Pitch. A note holding this reads as 0 on the panel.')
    w('M.PITCH_NEUTRAL = %d' % PITCH_NEUTRAL)
    w('')
    w('-- Which parameter each stored column is, in order.')
    w('M.FIELDS = { %s }' % ', '.join("'%s'" % i for i in ids))
    w('')
    w('-- The instrument maps, by Bank LSB.')
    w('M.MAP_NAMES = {')
    for lsb, _, _, label in MAPS:
        w('  [%d] = %s,' % (lsb, lua_str(label)))
    w('}')
    w('')
    w('-- [bank lsb] = { [program change] = name }')
    w('M.KIT_NAMES = {')
    for lsb, _, _, _ in MAPS:
        w('  [%d] = {' % lsb)
        for pc in sorted(names[lsb]):
            w('    [%d] = %s,' % (pc, lua_str(names[lsb][pc])))
        w('  },')
    w('}')
    w('')
    w('-- [bank lsb] = { [program change] = { [note] = { %s } } }'
      % ', '.join(ids))
    w('M.MAPS = {')
    for lsb, _, _, _ in MAPS:
        by_key = maps[lsb]
        w('  [%d] = {' % lsb)
        for pc in sorted({pc for pc, _ in by_key}):
            w('    [%d] = {' % pc)
            for note in sorted(n for p, n in by_key if p == pc):
                w('      [%d] = { %s },'
                  % (note, ', '.join(str(v) for v in by_key[(pc, note)])))
            w('    },')
        w('  },')
    w('}')
    w('')
    w('return M')

    with open(OUT, 'w', newline='', encoding='ascii') as f:
        f.write('\r\n'.join(out) + '\r\n')

    total_kits = sum(len(names[lsb]) for lsb in names)
    total_notes = sum(len(maps[lsb]) for lsb in maps)
    print('%d maps, %d kits, %d notes -> %s'
          % (len(maps), total_kits, total_notes, os.path.relpath(OUT, ROOT)))
    for lsb, _, _, label in MAPS:
        print('  %-9s bank LSB %d: %2d kits, %4d notes'
              % (label, lsb, len(names[lsb]), len(maps[lsb])))
    print('kit names taken from the shipped .reabank files')
    print('column order held against %d rows of the GSAE Drum Window'
          % window_rows)


if __name__ == '__main__':
    main()
