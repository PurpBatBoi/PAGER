-- PAGER - voices.lua: the .reabank parser and voice lookup.
--
-- Parses the real SC-8850 maps that ship beside the editor, because the
-- thing worth testing is that THOSE files produce the names the Part editor
-- shows -- a parser that is correct against a handmade fixture and wrong
-- against the shipped data would be a passing test and a broken editor.

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' .. package.path

local H = require 'harness'
local check = H.check

_G.reaper = { get_action_context = function()
  return false, dir .. '/../editor/x.lua'
end }

local V = require 'voices'

-- the shipped maps ---------------------------------------------------------

do
  check(V.error() == nil, 'both maps must load: ' .. tostring(V.error()))

  local tone, drum = V.banks(false, 4), V.banks(true, 4)
  check(#tone == 51, 'the SC-8850 tone map has 51 banks, got ' .. #tone)
  check(#drum == 1, 'the drum map has 1 bank, got ' .. #drum)

  -- Power-on: every Part is a Grand Piano, Part 10 a drum kit. These two
  -- names are what the Overview shows before anything is changed.
  check(V.name(false, 0, 4, 0) == 'Piano 1',
    'Bank 0/4 PC 0 must be Piano 1, got ' .. tostring(V.name(false, 0, 4, 0)))
  check(V.name(true, 0, 4, 0) == 'STANDARD 1',
    'the drum map default must be STANDARD 1, got ' ..
    tostring(V.name(true, 0, 4, 0)))

  -- The two maps are separate: the same address names different sounds.
  check(V.name(false, 0, 4, 0) ~= V.name(true, 0, 4, 0),
    'a drum Part and a normal Part must not share a voice list')

  -- The banks are SPARSE. Variation bank 1 jumps from PC 2 to PC 5, and a
  -- lookup table indexed by PC would invent voices at 3 and 4 that the
  -- hardware does not have.
  check(V.name(false, 1, 4, 3) == nil,
    'an empty slot must name nothing, got ' .. tostring(V.name(false, 1, 4, 3)))
  check(V.name(false, 1, 4, 5) == 'E.Piano 3',
    'but the slot after it is real, got ' .. tostring(V.name(false, 1, 4, 5)))

  -- An address in no bank at all.
  check(V.name(false, 99, 99, 0) == nil, 'an unknown bank names nothing')

  H.pass('the shipped SC-8850 maps parse and look up correctly (9 cases)')
end

-- the four instrument maps -------------------------------------------------

-- The SC-8850 can sound any of its predecessors' maps, selected by Bank
-- Select LSB. Getting that byte wrong does not error -- it plays a real but
-- wrong instrument out of another module's sound set.
do
  check(#V.MAPS == 4, 'four maps, got ' .. #V.MAPS)

  local want = { { 'SC-55', 1 }, { 'SC-88', 2 }, { 'SC-88Pro', 3 },
                 { 'SC-8850', 4 } }
  for i, w in ipairs(want) do
    check(V.MAPS[i].name == w[1] and V.MAPS[i].lsb == w[2],
      ('map %d must be %s with LSB %d, got %s/%s'):format(
        i, w[1], w[2], V.MAPS[i].name, tostring(V.MAPS[i].lsb)))
  end

  -- Every map loads its own voices, and the newer modules have more.
  local counts = {}
  for _, m in ipairs(V.MAPS) do
    local n = 0
    for _, b in ipairs(V.banks(false, m.lsb)) do n = n + #b.voices end
    counts[#counts + 1] = n
    check(n > 0, m.name .. ' must have voices')
  end
  for i = 2, #counts do
    check(counts[i] > counts[i - 1],
      'each map adds voices to the one before it, got ' ..
      table.concat(counts, ' < '))
  end

  -- An LSB that names no map yields nothing rather than another map's list.
  check(#V.banks(false, 99) == 0, 'an unknown map has no voices')
  check(V.map_of(4).name == 'SC-8850', 'LSB 4 is the SC-8850 map')
  check(V.map_of(99) == nil, 'and LSB 99 is no map at all')

  H.pass('all four instrument maps load and are selected by Bank LSB (13 cases)')
end

-- categories ---------------------------------------------------------------

-- Roland's own groupings, from the GM 2 Instrument List (manual p.213-214).
do
  check(#V.CATEGORIES == 16, 'sixteen categories, got ' .. #V.CATEGORIES)

  -- The boundaries the manual prints, as zero-based program numbers.
  local CASES = {
    { 0, 'Piano' }, { 7, 'Piano' },
    { 8, 'Chromatic Percussion' },
    { 16, 'Organ' }, { 24, 'Guitar' }, { 32, 'Bass' },
    { 40, 'Orchestra' }, { 48, 'Ensemble' }, { 56, 'Brass' },
    { 64, 'Reed' }, { 72, 'Pipe' }, { 80, 'Synth Lead' },
    { 88, 'Synth Pad' }, { 96, 'Synth SFX' }, { 104, 'Ethnic Misc' },
    { 112, 'Percussive' }, { 120, 'SFX' }, { 127, 'SFX' },
  }
  for _, c in ipairs(CASES) do
    check(V.category(c[1]) == c[2],
      ('PC %d is %s, got %s'):format(c[1], c[2], V.category(c[1])))
  end

  -- Grouping loses nothing: every voice lands in exactly one category.
  local grouped, flat = 0, 0
  for _, g in ipairs(V.by_category(false, 4)) do grouped = grouped + #g.voices end
  for _, b in ipairs(V.banks(false, 4)) do flat = flat + #b.voices end
  check(grouped == flat,
    ('every voice must be categorised: %d grouped vs %d total')
      :format(grouped, flat))

  -- Drum sets are not melodic instruments, so the GM families do not
  -- describe them and the drum map stays one group.
  local drums = V.by_category(true, 4)
  check(#drums == 1 and drums[1].name == 'Drum Sets',
    'the drum map is one group, not sixteen')

  H.pass("voices group into Roland's sixteen categories (22 cases)")
end

-- ambiguous names ----------------------------------------------------------

-- The picker prints a voice's bank only where the name alone would not say
-- which voice it is. Nearly every name is unique inside its category, so the
-- suffix is noise on almost every row -- but the few that repeat still need
-- it, or two identical rows are the only thing the user sees.
do
  local groups = V.by_category(false, 4)

  local flagged, total = 0, 0
  for _, g in ipairs(groups) do
    local seen = {}
    for _, v in ipairs(g.voices) do
      total = total + 1
      if v.ambiguous then flagged = flagged + 1 end
      -- Whatever is flagged must really be a repeat, and whatever repeats
      -- must really be flagged.
      if seen[v.name] then
        check(v.ambiguous, v.name .. ' repeats and must be marked ambiguous')
        check(seen[v.name].ambiguous,
          'and so must the first ' .. v.name .. ' -- both rows look alike')
      end
      seen[v.name] = v
    end
  end

  check(flagged > 0, 'some names do repeat, so the marking must do something')
  check(flagged < total / 10,
    ('the suffix must stay rare: %d of %d rows flagged'):format(flagged, total))

  -- A name that appears once is never flagged: Piano 2 is unique in Piano.
  for _, g in ipairs(groups) do
    if g.name == 'Piano' then
      for _, v in ipairs(g.voices) do
        if v.name == 'Piano 2' then
          check(not v.ambiguous, 'a unique name needs no bank suffix')
        end
      end
    end
  end

  H.pass('only ambiguous voice names carry their bank (4+ cases)')
end

-- parsing rules -------------------------------------------------------------

do
  local banks = V.parse([[
; a comment, and the blank line below

Bank 0 4 First [SC8850]
0 Voice Zero
2 Voice Two
Bank 8 4 Second [SC8850]
0 Other Zero
]])

  check(#banks == 2, 'two Bank lines make two banks, got ' .. #banks)
  check(banks[1].msb == 0 and banks[1].lsb == 4,
    'the bank numbers are MSB then LSB')
  check(banks[1].name == 'First [SC8850]', 'the rest of the line is the name')
  check(#banks[1].voices == 2, 'voices attach to the bank above them')
  check(banks[2].voices[1].name == 'Other Zero',
    'and a later Bank line starts a new list')

  -- Order is the file's own: Capital Tones before the variations, which is
  -- the order the hardware presents them in.
  check(banks[1].msb == 0 and banks[2].msb == 8, 'bank order follows the file')

  -- A voice line before any Bank line has no bank to belong to.
  local orphan = V.parse('5 Homeless\nBank 0 4 Real\n1 Fine\n')
  check(#orphan == 1 and #orphan[1].voices == 1,
    'a voice before any Bank line is dropped, not given a home')

  H.pass('the .reabank format parses by its own rules (7 cases)')
end

