-- Plan 001, step 1: the shared drum map's protocol metadata.
--
-- The drum controls address nine per-note parameters on two shared maps, and
-- every one of them is a single byte at 41 mp rr -- m the map, p the
-- parameter nibble, rr the MIDI note. Nothing about that is visible on
-- screen: a transposed nibble still shows the right number in the panel, the
-- take still holds a SysEx event, and only the hardware edits the wrong
-- field.
--
-- So the addresses below are written out longhand from the SC-8850 manual
-- (pp.70-72 and p.240) rather than derived from the module they check. An
-- expectation built by calling GS.drum_param_addr would agree with a wrong
-- implementation perfectly.
--
-- Nothing here encodes a value; drum_messages.lua is tested separately.
--   lua tests/test_drum_params.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local GS = require 'gs_sysex'
local D = require 'drum_params'
local check = H.check

-- addresses ------------------------------------------------------------------

local function addr_str(a)
  return ('%02X %02X %02X'):format(a[1], a[2], a[3])
end

-- The four literal examples from the plan's protocol oracle, transcribed by
-- hand. DRUM 1 is m = 0 and DRUM 2 is m = 1, so the middle byte is the
-- parameter nibble for map 1 and 0x10 + it for map 2.
local ADDR_CASES = {
  { mode = 1, nibble = 1, note = 0,   want = '41 01 00' }, -- DRUM 1 Pitch, note 0
  { mode = 1, nibble = 2, note = 75,  want = '41 02 4B' }, -- DRUM 1 Level, note 75
  { mode = 2, nibble = 9, note = 127, want = '41 19 7F' }, -- DRUM 2 Delay, note 127
  { mode = 2, nibble = 8, note = 60,  want = '41 18 3C' }, -- DRUM 2 Rx Note On
}
for _, c in ipairs(ADDR_CASES) do
  local got = addr_str(GS.drum_param_addr(c.mode, c.nibble, c.note))
  check(got == c.want,
    ('drum_param_addr(%d, %d, %d) = %s, expected %s')
      :format(c.mode, c.nibble, c.note, got, c.want))
end

-- Every nibble on both maps lands in its own middle byte, and the note is
-- carried through untouched. The two maps must never collide: that is the
-- whole reason the map is in the address rather than beside it.
for nibble = 1, 9 do
  local a1 = GS.drum_param_addr(1, nibble, 0)
  local a2 = GS.drum_param_addr(2, nibble, 0)
  check(a1[1] == 0x41 and a2[1] == 0x41, 'the drum block is 41')
  check(a1[2] == nibble, 'DRUM 1 nibble ' .. nibble .. ' must be its own byte')
  check(a2[2] == 0x10 + nibble, 'DRUM 2 nibble ' .. nibble .. ' must be 1x')
  check(a1[2] ~= a2[2], 'the two maps must not share a middle byte')
end

for _, note in ipairs({ 0, 1, 59, 60, 126, 127 }) do
  check(GS.drum_param_addr(1, 1, note)[3] == note,
    'the note is the third address byte, unchanged')
end

-- Invalid map, nibble or note must be rejected rather than producing an
-- address that looks plausible and writes into a neighbouring field.
check(not pcall(GS.drum_param_addr, 0, 1, 0), 'map 0 must be rejected')
check(not pcall(GS.drum_param_addr, 3, 1, 0), 'map 3 must be rejected')
check(not pcall(GS.drum_param_addr, 1, 0, 0), 'nibble 0 must be rejected')
check(not pcall(GS.drum_param_addr, 1, 10, 0), 'nibble 10 must be rejected')
check(not pcall(GS.drum_param_addr, 1, 1, -1), 'note -1 must be rejected')
check(not pcall(GS.drum_param_addr, 1, 1, 128), 'note 128 must be rejected')
check(not pcall(GS.drum_param_addr, 1, 1, 60.5), 'a fractional note must be rejected')
check(not pcall(GS.drum_param_addr, 1, 1, 'x'), 'a non-numeric note must be rejected')
H.pass('drum addresses are 41 mp rr, per map, nibble and note (41 cases)')

-- the rows -------------------------------------------------------------------

-- Nine rows, in the order the panel shows them. This is NOT protocol order --
-- Rx Note Off has the lower nibble but sits after Rx Note On on screen -- so
-- the two are asserted separately and a sort that "tidied" the list would
-- fail here.
local UI_ORDER = {
  'pitch', 'level', 'assign_group', 'pan',
  'reverb', 'chorus', 'delay', 'rx_note_on', 'rx_note_off',
}

check(#D.PARAMS == 9, 'nine drum parameters, got ' .. #D.PARAMS)
for i, id in ipairs(UI_ORDER) do
  check(D.PARAMS[i] and D.PARAMS[i].id == id,
    ('drum row %d must be %s, got %s')
      :format(i, id, tostring(D.PARAMS[i] and D.PARAMS[i].id)))
end

local seen = {}
for _, p in ipairs(D.PARAMS) do
  check(not seen[p.id], 'duplicate drum param id: ' .. p.id)
  seen[p.id] = true
  check(D.BY_ID[p.id] == p, p.id .. ' must be reachable through BY_ID')
end

-- Range, display kind and address nibble, one line per row, from the manual.
local ROWS = {
  -- PLAY NOTE NUMBER is an absolute 00..7F on the wire, but the panel and
  -- the factory data both show it relative to a neutral 60 -- so the
  -- canonical range is the wire range shifted by that, and is asymmetric.
  { id = 'pitch',        name = 'Pitch',        nibble = 1, min = -60, max = 67,  display = 'plain' },
  { id = 'level',        name = 'Level',        nibble = 2, min = 0,   max = 127, display = 'plain' },
  { id = 'assign_group', name = 'Assign Group', nibble = 3, min = 0,   max = 127, display = 'plain' },
  { id = 'pan',          name = 'Pan',          nibble = 4, min = -64, max = 63,  display = 'plain' },
  { id = 'reverb',       name = 'Reverb',       nibble = 5, min = 0,   max = 127, display = 'plain' },
  { id = 'chorus',       name = 'Chorus',       nibble = 6, min = 0,   max = 127, display = 'plain' },
  { id = 'delay',        name = 'Delay',        nibble = 9, min = 0,   max = 127, display = 'plain' },
  { id = 'rx_note_on',   name = 'Rx Note On',   nibble = 8, min = 0,   max = 1,   display = 'switch' },
  { id = 'rx_note_off',  name = 'Rx Note Off',  nibble = 7, min = 0,   max = 1,   display = 'switch' },
}
for _, want in ipairs(ROWS) do
  local p = D.BY_ID[want.id]
  check(p, 'missing drum row ' .. want.id)
  check(p.name == want.name,
    ('%s label is %s, expected %s'):format(want.id, tostring(p.name), want.name))
  check(p.nibble == want.nibble,
    ('%s nibble is %s, expected %d'):format(want.id, tostring(p.nibble), want.nibble))
  check(p.min == want.min and p.max == want.max,
    ('%s range is %s..%s, expected %d..%d')
      :format(want.id, tostring(p.min), tostring(p.max), want.min, want.max))
  check(p.display == want.display,
    ('%s display is %s, expected %s')
      :format(want.id, tostring(p.display), want.display))
end

-- The two switches are exactly the two Rx rows; everything else is a slider.
-- The panel keys its widget choice off this, so a row that changed kind would
-- silently become the wrong control.
local switches = 0
for _, p in ipairs(D.PARAMS) do
  if p.display == 'switch' then
    switches = switches + 1
    check(p.id:sub(1, 3) == 'rx_', 'only the Rx rows are switches, not ' .. p.id)
    check(p.min == 0 and p.max == 1, p.id .. ' must be a 0..1 switch')
  end
end
check(switches == 2, 'exactly two switch rows, got ' .. switches)

-- Every nibble is used once. Two rows sharing one would write to the same
-- hardware field and each would appear to work.
local by_nibble = {}
for _, p in ipairs(D.PARAMS) do
  check(not by_nibble[p.nibble],
    'nibble ' .. p.nibble .. ' is claimed by two rows')
  by_nibble[p.nibble] = p.id
  check(p.nibble >= 1 and p.nibble <= 9,
    p.id .. ': nibble must be 1..9, got ' .. tostring(p.nibble))
end
H.pass('nine drum rows, in panel order, with distinct nibbles (60 cases)')

-- validation ------------------------------------------------------------------

-- map and note --------------------------------------------------------------

check(D.valid_mode(1) and D.valid_mode(2), 'DRUM 1 and DRUM 2 are the maps')
for _, bad in ipairs({ 0, 3, -1, 1.5, 'x' }) do
  check(not D.valid_mode(bad), 'map ' .. tostring(bad) .. ' must be rejected')
end

check(D.valid_note(0) and D.valid_note(127) and D.valid_note(60),
  'notes 0..127 are the range')
for _, bad in ipairs({ -1, 128, 60.5, 'x' }) do
  check(not D.valid_note(bad), 'note ' .. tostring(bad) .. ' must be rejected')
end

-- Out-of-range values are DROPPED, not clamped: the same rule part_params
-- follows, so a restored value that came back wrong is visible rather than
-- quietly moved to an endpoint.
check(D.validate(D.BY_ID.level, 100) == 100, 'an in-range value survives')
check(D.validate(D.BY_ID.level, 0) == 0, 'the low endpoint is in range')
check(D.validate(D.BY_ID.level, 127) == 127, 'the high endpoint is in range')
check(D.validate(D.BY_ID.level, 128) == nil, 'above range is dropped')
check(D.validate(D.BY_ID.level, -1) == nil, 'below range is dropped')
check(D.validate(D.BY_ID.pan, -64) == -64, 'Pan reaches -64, which is Random')
check(D.validate(D.BY_ID.pan, 63) == 63, 'Pan reaches +63')
check(D.validate(D.BY_ID.pan, 64) == nil, 'Pan stops at +63')
check(D.validate(D.BY_ID.pan, -65) == nil, 'Pan stops at -64')
check(D.validate(D.BY_ID.rx_note_on, 1) == 1, 'a switch accepts 1')
check(D.validate(D.BY_ID.rx_note_on, 2) == nil, 'a switch rejects 2')
check(D.validate(D.BY_ID.level, 'x') == nil, 'a non-number is dropped')
check(D.validate(D.BY_ID.level, 0/0) == nil, 'NaN is dropped')
H.pass('map, note and value validation drop rather than clamp (25 cases)')

-- the factory seed --------------------------------------------------------------

-- A note seeds from the SC-8850's OWN values for that instrument on that kit.
-- They are not uniform -- that is the whole reason the table is shipped -- so
-- the cases below are transcribed from the hardware panel rather than derived
-- from the table they check.

-- Two readings off Sound Canvas VA, STANDARD 1 (program change 0). Both are
-- screenshots of the real editor, which is the only oracle there is for this
-- data short of the device itself.
do
  -- note 24, "Concert Snr": Pitch 0, Level 120, Pan C, Reverb 50, Group Non
  local s = D.seed_values(24, 0, 4)
  check(s.pitch == 0, 'note 24 pitch is 0, got ' .. tostring(s.pitch))
  check(s.level == 120, 'note 24 level is 120, got ' .. tostring(s.level))
  check(s.pan == 0, 'note 24 pan is centre, got ' .. tostring(s.pan))
  check(s.reverb == 50, 'note 24 reverb is 50, got ' .. tostring(s.reverb))
  check(s.assign_group == 0, 'note 24 assign group is Non')

  -- note 22, "MC-500 Beep": Pitch 12, Level 107, Pan C, Reverb 0, Group Non
  local b = D.seed_values(22, 0, 4)
  check(b.pitch == 12, 'note 22 pitch is +12, got ' .. tostring(b.pitch))
  check(b.level == 107, 'note 22 level is 107, got ' .. tostring(b.level))
  check(b.reverb == 0, 'note 22 reverb is 0, got ' .. tostring(b.reverb))
  check(b.pan == 0, 'note 22 pan is centre')

  -- The two differ, which is the point: one flat seed would misreport both.
  check(s.reverb ~= b.reverb and s.pitch ~= b.pitch,
    'two notes of one kit must be allowed to differ')
end

-- The hi-hats share a cut group, so playing one stops the others. Three
-- notes, one group, non-zero -- the property that identified the column.
do
  local closed = D.seed_values(42, 0, 4)
  local pedal = D.seed_values(44, 0, 4)
  local open = D.seed_values(46, 0, 4)
  check(closed.assign_group ~= 0, 'the closed hi-hat is in a cut group')
  check(closed.assign_group == pedal.assign_group
        and pedal.assign_group == open.assign_group,
    'all three hi-hats must share one group')
  -- A kick is not in that group: it must ring through a hi-hat.
  check(D.seed_values(36, 0, 4).assign_group ~= closed.assign_group,
    'the kick must not share the hi-hat group')
end

-- Rx Note Off is on only for SUSTAINED instruments, which need a note-off to
-- stop. Note 25 of STANDARD 1 is a snare roll; note 36 is a kick.
do
  check(D.seed_values(25, 0, 4).rx_note_off == 1,
    'a snare roll must receive note off')
  check(D.seed_values(36, 0, 4).rx_note_off == 0,
    'a kick must not')
  check(D.seed_values(36, 0, 4).rx_note_on == 1, 'but it must receive note on')
end

-- The same note differs between kits, which is why the kit is an argument.
do
  local std = D.seed_values(38, 0, 4)     -- STANDARD 1 snare
  local differs = false
  for _, pc in ipairs({ 8, 16, 24, 25 }) do   -- ROOM, POWER, ELECTRONIC, TR-808
    local other = D.seed_values(38, pc, 4)
    for _, id in ipairs({ 'pitch', 'level', 'reverb', 'pan' }) do
      if other[id] ~= std[id] then differs = true end
    end
  end
  check(differs, 'note 38 must not be identical across every kit')
end

-- Pan carries the hardware's Random endpoint. Canonical -64 is Random, and
-- an ordinary centred instrument is 0.
do
  for _, pc in ipairs({ 0, 8, 16 }) do
    for note = 0, 127 do
      local s = D.seed_values(note, pc, 4)
      check(s.pan >= -64 and s.pan <= 63,
        ('kit %d note %d pan %s outside -64..63'):format(pc, note, tostring(s.pan)))
    end
  end
end

-- Every seeded value, on every kit and every note, must survive the very
-- validator that restores it. A seed outside its own row's range would be
-- dropped on reload and silently replaced.
--
-- One exception, kept verbatim from GSAE: JUNGLE (pc 10) note 105 stores
-- Rx Note Off 12. The panel draws it as a checkbox reading On, and a click
-- writes 0 or 1, so the raw 12 is never encoded.
do
  local kits, notes = 0, 0
  for pc in pairs(D.KIT_NAMES[4]) do
    kits = kits + 1
    for note = 0, 127 do
      local s = D.seed_values(note, pc, 4)
      notes = notes + 1
      for _, p in ipairs(D.PARAMS) do
        local gsae_odd = pc == 10 and note == 105 and p.id == 'rx_note_off'
        check(s[p.id] ~= nil, ('kit %d note %d: missing %s'):format(pc, note, p.id))
        check(gsae_odd and s[p.id] == 12 or D.validate(p, s[p.id]) ~= nil,
          ('kit %d note %d: %s = %s is outside %d..%d')
            :format(pc, note, p.id, tostring(s[p.id]), p.min, p.max))
      end
    end
  end
  check(kits == 38, 'all 38 factory kits must be present, got ' .. kits)
  check(notes == kits * 128, 'every note of every kit must seed')
end

-- Chorus and Delay are absent from the source table and always seed 0, which
-- is also their power-on value. Stated as a test so a future extractor that
-- recovers them fails here rather than silently changing the panel.
do
  for _, pc in ipairs({ 0, 8, 25 }) do
    for _, note in ipairs({ 24, 36, 42, 60 }) do
      local s = D.seed_values(note, pc, 4)
      check(s.chorus == 0 and s.delay == 0,
        ('kit %d note %d must seed chorus and delay 0'):format(pc, note))
    end
  end
end

-- An unknown kit, and no kit at all, fall back to the generic seed rather
-- than raising: any kit outside the table still has to show something.
do
  for _, kit in ipairs({ 3, 99, 126 }) do
    check(not D.has_kit(kit, 4), 'kit ' .. kit .. ' is not in the factory table')
    local s = D.seed_values(60, kit, 4)
    check(s.level == 127 and s.pitch == 0,
      'an unknown kit must fall back to the generic seed')
  end
  local none = D.seed_values(60, nil, 4)
  check(none.level == 127 and none.pitch == 0,
    'no kit at all must fall back too')
  check(D.has_kit(0, 4) and D.has_kit(127, 4), 'the real kits must be recognised')

  -- The Drum Overview's rows: a covered kit lists its notes ascending, an
  -- unknown one lists none so the grid falls back to all 128.
  local notes = D.kit_notes(0, 1)
  check(notes and notes[1] == 27 and notes[#notes] == 87,
    'SC-55 STANDARD spans notes 27..87')
  for i = 2, #notes do check(notes[i] > notes[i - 1], 'in ascending order') end
  check(D.kit_notes(3, 4) == nil, 'an unknown kit has no note list')
end

-- A fresh table each call: two notes sharing one would make editing note 0
-- silently change note 60.
do
  local a, b = D.seed_values(24, 0, 4), D.seed_values(24, 0, 4)
  check(a ~= b, 'each call must return its own table')
  a.level = 1
  check(b.level == 120, 'and they must not share storage')
end

check(not pcall(D.seed_values, 128, 0, 4), 'seeding an invalid note must be rejected')
check(not pcall(D.seed_values, 'x', 0, 4), 'and a non-numeric one')
H.pass('notes seed from the factory table, per kit, inside every range (4900+ cases)')

H.pass('drum_params: metadata, addresses, validation and seeds')
