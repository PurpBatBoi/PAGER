-- The generated factory drum tables, for all four instrument maps.
--
-- editor/drum_defaults.lua is produced by scripts/extract_drum_defaults.py
-- from the GSAE decompilation. Generated data still needs checking: the
-- extractor can only assert what it knows to look for, and a regeneration
-- that silently changed a column or dropped a kit would reach the panel as
-- wrong values for real instruments rather than as an error.
--
-- The anchors here are transcribed from the hardware. Sound Canvas VA,
-- STANDARD 1: note 24 "Concert Snr" reads Pitch 0, Level 120, Pan C,
-- Reverb 50, Assign Group Non; note 22 "MC-500 Beep" reads Pitch 12,
-- Level 107, Reverb 0. Those are the only external truth available short of
-- the device, so they are written out longhand and never derived.
--   lua tests/test_drum_defaults.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local DD = require 'drum_defaults'
local D = require 'drum_params'
local check = H.check

-- shape ------------------------------------------------------------------------

check(DD.PITCH_NEUTRAL == 60, 'the neutral PLAY NOTE NUMBER is 60')

-- All nine parameters, in the order GSAE's own Drum Window draws its columns.
-- That order is what the whole table means: a regeneration that moved one
-- column would put every value under the wrong parameter and still load.
local WANT_FIELDS = { 'pitch', 'level', 'assign_group', 'pan', 'reverb',
                      'chorus', 'rx_note_off', 'rx_note_on', 'delay' }
check(#DD.FIELDS == #WANT_FIELDS, 'nine stored columns, got ' .. #DD.FIELDS)
for i, id in ipairs(WANT_FIELDS) do
  check(DD.FIELDS[i] == id,
    ('column %d is %s, expected %s'):format(i, tostring(DD.FIELDS[i]), id))
  check(D.BY_ID[id], 'column ' .. id .. ' must be a real drum parameter')
end

-- Which stored column holds one parameter. Looked up rather than hardcoded:
-- the column order is exactly what these tests exist to pin, so a literal
-- index here would silently follow a regeneration that moved it.
local function col(id)
  for i, name in ipairs(DD.FIELDS) do
    if name == id then return i end
  end
  check(false, 'no stored column for ' .. id)
end

-- Every drum parameter the panel shows must be covered; a missing one would
-- silently seed from the generic fallback instead of the factory table.
for _, p in ipairs(D.PARAMS) do
  local found = false
  for _, id in ipairs(DD.FIELDS) do
    if id == p.id then found = true end
  end
  check(found, p.id .. ' must be extracted from the source table')
end

-- Four instrument maps, keyed by Bank LSB, each with its own kits.
local WANT_MAPS = { [1] = 'SC-55', [2] = 'SC-88',
                    [3] = 'SC-88Pro', [4] = 'SC-8850' }
for lsb, name in pairs(WANT_MAPS) do
  check(DD.MAP_NAMES[lsb] == name,
    ('bank LSB %d is %s, got %s'):format(lsb, name, tostring(DD.MAP_NAMES[lsb])))
  check(type(DD.MAPS[lsb]) == 'table', name .. ' must ship kits')
  check(type(DD.KIT_NAMES[lsb]) == 'table', name .. ' must ship kit names')
end

-- Kit counts per map, from the .reabank files the editor already ships.
local WANT_KITS = { [1] = 10, [2] = 15, [3] = 26, [4] = 38 }
for lsb, want in pairs(WANT_KITS) do
  local n = 0
  for _ in pairs(DD.MAPS[lsb]) do n = n + 1 end
  check(n == want, ('%s has %d kits, expected %d')
    :format(DD.MAP_NAMES[lsb], n, want))
end

-- User Drum Sets are not factory data: SC-88 and SC-88Pro program changes
-- 64 and 65 are user slots and must not have been shipped.
for _, lsb in ipairs({ 2, 3 }) do
  for _, pc in ipairs({ 64, 65 }) do
    check(DD.MAPS[lsb][pc] == nil,
      ('%s pc %d is a User Drum Set and must not be shipped')
        :format(DD.MAP_NAMES[lsb], pc))
  end
end

-- The same program change names a DIFFERENT kit in each map, which is why a
-- kit is (map, program change) rather than a program change alone.
check(DD.KIT_NAMES[1][0] == 'STANDARD', 'SC-55 pc 0 is STANDARD')
check(DD.KIT_NAMES[4][0] == 'STANDARD 1', 'SC-8850 pc 0 is STANDARD 1')

-- Every kit of every map carries a name, from the .reabank files.
for lsb in pairs(WANT_MAPS) do
  for pc in pairs(DD.MAPS[lsb]) do
    local name = DD.KIT_NAMES[lsb][pc]
    check(type(name) == 'string' and #name > 0,
      ('%s kit %d must be named'):format(DD.MAP_NAMES[lsb], pc))
  end
end
check(DD.KIT_NAMES[1][8] == 'ROOM', 'SC-55 pc 8 is ROOM')
check(DD.KIT_NAMES[4][25] == 'TR-808', 'SC-8850 pc 25 is TR-808')
H.pass('four maps, 89 named kits, a known column order (80 cases)')

-- the hardware anchors ------------------------------------------------------------

-- Raw stored bytes, exactly as the panel readings imply them.
local ANCHORS = {
  { pc = 0, note = 24, name = 'Concert Snr',
    pitch = 60, level = 120, assign_group = 0, pan = 64, reverb = 50 },
  { pc = 0, note = 22, name = 'MC-500 Beep',
    pitch = 72, level = 107, assign_group = 0, pan = 64, reverb = 0 },
}
for _, a in ipairs(ANCHORS) do
  local row = DD.MAPS[4][a.pc][a.note]
  check(row, ('%s (kit %d note %d) must be present'):format(a.name, a.pc, a.note))
  for i, id in ipairs(DD.FIELDS) do
    if a[id] ~= nil then
      check(row[i] == a[id],
        ('%s %s is %d, the panel shows %d'):format(a.name, id, row[i], a[id]))
    end
  end
end

-- The two differ, which is the entire reason this table exists: one flat
-- seed would misreport both.
do
  local snr = DD.MAPS[4][0][24]
  local beep = DD.MAPS[4][0][22]
  check(snr[col('reverb')] ~= beep[col('reverb')],
    'the two anchors must differ in Reverb')
  check(snr[col('pitch')] ~= beep[col('pitch')], 'and in Pitch')
end
H.pass('the two hardware panel readings match byte for byte (12 cases)')

-- GSAE's own Drum Window --------------------------------------------------------

-- The fixture that pins the COLUMN ORDER itself, rather than one column's
-- plausibility: eighteen rows of SC-55 STANDARD read off the application that
-- owns the data, all nine columns at once.
--
-- Transcribed from a screenshot. Building these by reading the same bytes
-- they check would agree with a wrong column order perfectly.
do
  -- pitch, level, assign group, panpot, reverb, chorus, rx off, rx on, delay
  local WINDOW = {
    [27] = { 60, 79, 0, 49, 127, 127, 0, 1, 0 },   -- High Q
    [28] = { 60, 107, 0, 49, 127, 127, 0, 1, 0 },  -- Slap
    [29] = { 60, 87, 7, 54, 63, 63, 0, 1, 0 },     -- Scr.Push
    [30] = { 60, 91, 7, 54, 63, 63, 0, 1, 0 },     -- Scr.Pull
    [31] = { 60, 115, 0, 64, 63, 63, 0, 1, 0 },    -- Sticks
    [32] = { 60, 127, 0, 54, 0, 0, 0, 1, 0 },      -- Sq.Click
    [35] = { 60, 127, 0, 64, 32, 32, 0, 1, 0 },    -- Kick 2
    [36] = { 60, 127, 0, 64, 32, 32, 0, 1, 0 },    -- Kick 1
    [41] = { 48, 127, 0, 34, 127, 127, 0, 1, 0 },  -- LowTom 2, pitch below neutral
    [42] = { 60, 123, 1, 84, 31, 31, 0, 1, 0 },    -- Closd HH, assign group 1
    [43] = { 52, 127, 0, 46, 127, 127, 0, 1, 0 },  -- LowTom 1
    [44] = { 60, 87, 1, 84, 32, 32, 0, 1, 0 },     -- Pedal HH
    [45] = { 55, 127, 0, 58, 127, 127, 0, 1, 0 },  -- MidTom 2
    [46] = { 60, 119, 1, 84, 31, 31, 0, 1, 0 },    -- Open HH
    [49] = { 60, 127, 0, 84, 127, 127, 0, 1, 0 },  -- CrshCym1
    [55] = { 69, 83, 0, 54, 127, 127, 0, 1, 0 },   -- SplshCym, pitch above neutral
    [63] = { 65, 107, 0, 39, 127, 127, 0, 1, 0 },  -- OH Conga
    [67] = { 65, 99, 0, 29, 100, 100, 0, 1, 0 },   -- Hi.Agogo
  }

  local rows = 0
  for note, want in pairs(WINDOW) do
    local row = DD.MAPS[1][0][note]
    check(row, 'SC-55 STANDARD note ' .. note .. ' must be present')
    check(#row == #want,
      ('note %d has %d columns, the window shows %d'):format(note, #row, #want))
    for i, id in ipairs(DD.FIELDS) do
      check(row[i] == want[i],
        ('SC-55 STANDARD note %d: %s is %d, the window shows %d')
          :format(note, id, row[i], want[i]))
    end
    rows = rows + 1
  end
  check(rows == 18, 'all eighteen window rows must be checked, got ' .. rows)

  -- The columns this fixture is really here to distinguish. Chorus and Delay
  -- were once assumed absent, and the two Rx columns are a swap waiting to
  -- happen -- each is asserted through a row where it differs from its
  -- neighbours.
  check(DD.MAPS[1][0][42][col('assign_group')] == 1,
    'the closed hi-hat carries its cut group')
  check(DD.MAPS[1][0][27][col('chorus')] == 127,
    'Chorus is a real column in the SC-55 map, not always zero')
  check(DD.MAPS[1][0][27][col('delay')] == 0, 'and Delay sits beside it')
  check(DD.MAPS[1][0][41][col('pitch')] == 48,
    'LowTom 2 is pitched below the neutral 60')
  check(DD.MAPS[1][0][55][col('pitch')] == 69,
    'and SplshCym above it')
  H.pass('all nine columns match the GSAE Drum Window, SC-55 STANDARD (18 rows)')
end

-- The same window, SC-55 ROOM. A second kit, because one kit proves only the
-- column ORDER -- two prove the per-kit lookup reaches the right row as well.
--
-- ROOM shares most of its percussion with STANDARD but replaces every tom
-- with a room-miked one, pitched 36..76 where STANDARD sits at 48..66. That
-- is exactly where a kit mix-up would show, and where it would be invisible
-- if only one kit were ever checked.
do
  local WINDOW = {
    [39] = { 60, 99, 0, 54, 127, 127, 0, 1, 0 },   -- HandClap
    [41] = { 36, 127, 0, 34, 127, 127, 0, 1, 0 },  -- R.LTom 2
    [43] = { 44, 127, 0, 46, 127, 127, 0, 1, 0 },  -- R.LTom 1
    [45] = { 52, 127, 0, 58, 127, 127, 0, 1, 0 },  -- R.MTom 2
    [47] = { 60, 127, 0, 70, 127, 127, 0, 1, 0 },  -- R.MTom 1
    [48] = { 68, 127, 0, 82, 127, 127, 0, 1, 0 },  -- R.HTom 2
    [50] = { 76, 127, 0, 94, 127, 127, 0, 1, 0 },  -- R.HTom 1
    [59] = { 61, 120, 0, 34, 127, 127, 0, 1, 0 },  -- RideCym2
    [69] = { 60, 95, 0, 29, 63, 63, 0, 1, 0 },     -- Cabasa
  }

  local rows = 0
  for note, want in pairs(WINDOW) do
    local row = DD.MAPS[1][8][note]
    check(row, 'SC-55 ROOM note ' .. note .. ' must be present')
    for i, id in ipairs(DD.FIELDS) do
      check(row[i] == want[i],
        ('SC-55 ROOM note %d: %s is %d, the window shows %d')
          :format(note, id, row[i], want[i]))
    end
    rows = rows + 1
  end
  check(rows == 9, 'all nine ROOM rows must be checked, got ' .. rows)

  -- The toms must NOT match STANDARD, or the lookup could be returning one
  -- kit for both and every assertion above would still pass.
  local pitch = col('pitch')
  for _, note in ipairs({ 41, 43, 45, 48, 50 }) do
    check(DD.MAPS[1][0][note][pitch] ~= DD.MAPS[1][8][note][pitch],
      ('note %d must differ between STANDARD and ROOM'):format(note))
  end

  -- HandClap's pan is 54 in both, which is what settled a misread screenshot
  -- earlier: the value was right and the reading was wrong.
  check(DD.MAPS[1][0][39][col('pan')] == 54
        and DD.MAPS[1][8][39][col('pan')] == 54,
    'HandClap sits at pan 54 in both kits')
  H.pass('a second kit confirms the per-kit lookup, SC-55 ROOM (9 rows)')
end



-- musical sanity --------------------------------------------------------------------

-- Assign Group is the column that groups instruments which must cut each
-- other off. The hi-hats are the canonical case, and they identify the
-- column: three notes, one non-zero group, in every kit that has all three.
--
-- Only the kits that actually PUT hi-hats on notes 42/44/46 can be checked
-- this way. The SC-8850 reuses those notes for unrelated sounds in the
-- specialised kits -- ORCHESTRA has timpani there, VOICE has vocal samples,
-- GAMELAN has gongs -- and those have no reason to share a cut group. The
-- drum kits proper are the ones this asserts.
do
  local DRUM_KITS = { 0, 1, 2, 8, 9, 10, 11, 12, 13, 16,
                      24, 25, 26, 27, 28, 29, 30, 32, 33, 40, 41, 42 }
  local grouped = 0
  for _, pc in ipairs(DRUM_KITS) do
    local notes = DD.MAPS[4][pc]
    check(notes, 'kit ' .. pc .. ' must be present')
    local hats = { notes[42], notes[44], notes[46] }
    check(hats[1] and hats[2] and hats[3],
      ('kit %d (%s) must have all three hi-hats'):format(pc, DD.KIT_NAMES[4][pc]))
    local grp = col('assign_group')
    local g = hats[1][grp]
    check(g ~= 0, ('kit %d (%s): the hi-hats must be in a cut group')
      :format(pc, DD.KIT_NAMES[4][pc]))
    check(hats[2][grp] == g and hats[3][grp] == g,
      ('kit %d (%s): all three hi-hats must share group %d, got %d/%d/%d')
        :format(pc, DD.KIT_NAMES[4][pc], g, hats[1][grp], hats[2][grp], hats[3][grp]))
    -- And a kick must ring through them rather than being cut off.
    if notes[36] then
      check(notes[36][grp] ~= g,
        ('kit %d (%s): the kick must not join the hi-hat group')
          :format(pc, DD.KIT_NAMES[4][pc]))
    end
    grouped = grouped + 1
  end
  check(grouped == #DRUM_KITS, 'every listed drum kit must have been checked')
end

-- Rx Note Off is on only for SUSTAINED instruments, which need a note-off to
-- stop. A snare roll does; a kick does not.
do
  local rxoff = col('rx_note_off')
  check(DD.MAPS[4][0][25][rxoff] == 1, 'the snare roll must receive note off')
  check(DD.MAPS[4][0][36][rxoff] == 0, 'the kick must not')

  -- It is a minority of notes overall -- most drums are one-shot hits. A
  -- column that was on everywhere would not be this one.
  local on, total = 0, 0
  for _, notes in pairs(DD.MAPS[4]) do
    for _, row in pairs(notes) do
      total = total + 1
      if row[rxoff] == 1 then on = on + 1 end
    end
  end
  check(on > 0, 'some instruments must receive note off')
  check(on < total / 4,
    ('note-off should be the minority, got %d of %d'):format(on, total))
end

-- Rx Note On is set on every shipped note except the ten GSAE itself holds
-- at 0: SC-8850 JUNGLE (pc 10) notes 105..113 and GAMELAN 2 (pc 55) note 73.
-- They are kept verbatim; anything else at 0 means a column moved.
do
  local rxon = col('rx_note_on')
  local odd = { [55] = { [73] = true }, [10] = {} }
  for n = 105, 113 do odd[10][n] = true end
  for pc, notes in pairs(DD.MAPS[4]) do
    for note, row in pairs(notes) do
      local want = (odd[pc] and odd[pc][note]) and 0 or 1
      check(row[rxon] == want,
        ('kit %d note %d has Rx Note On %d, GSAE holds %d')
          :format(pc, note, row[rxon], want))
    end
  end
end
H.pass('assign groups, note-off and record alignment all hold (100+ cases)')

-- ranges ----------------------------------------------------------------------------

-- Every stored byte must be a legal 7-bit value, and every one must survive
-- the conversion into the canonical range its parameter documents -- a value
-- outside it would be dropped by the very validator that restores it.
do
  local notes = 0
  for lsb, kits in pairs(DD.MAPS) do
  for pc, kit in pairs(kits) do
    for note, row in pairs(kit) do
      notes = notes + 1
      check(note >= 0 and note <= 127, 'kit ' .. pc .. ' has a note outside 0..127')
      check(#row == #DD.FIELDS,
        ('%s kit %d note %d has %d columns, expected %d')
          :format(DD.MAP_NAMES[lsb], pc, note, #row, #DD.FIELDS))
      for i, id in ipairs(DD.FIELDS) do
        local v = row[i]
        check(type(v) == 'number' and v == math.floor(v) and v >= 0 and v <= 127,
          ('%s kit %d note %d %s = %s is not a 7-bit value')
            :format(DD.MAP_NAMES[lsb], pc, note, id, tostring(v)))
      end
    end
  end
  end
  -- 602 + 938 + 2647 + 3680 across the four maps.
  check(notes == 7867, 'the tables ship 7867 notes, got ' .. notes)
end
H.pass('every stored byte of every map is a legal 7-bit value (7867 notes)')

H.pass('drum_defaults: generated factory data, checked against the hardware')
