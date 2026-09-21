-- PAGER - SC-8850 voice list.
--
-- Reads the .reabank files beside this script and answers two questions: what
-- voices exist, and what is the name of the one a Part is currently set to.
--
-- A .reabank is REAPER's own patch-name format, and the same file drives the
-- MIDI editor's program-change dropdown. Two of them describe the SC-8850:
-- the normal-tone map and the drum map, which are separate because a Part
-- set to a drum map selects from a different list entirely.
--
-- Format, as REAPER defines it:
--
--   ; comment
--   Bank <MSB> <LSB> <name>
--   <PC> <name>
--
-- Every `<PC> <name>` line belongs to the most recent Bank line. Numbers are
-- decimal and zero-based, which is also how they go on the wire -- the bank
-- numbers are Control Change values and the PC is a Program Change byte, so
-- nothing here is off by one against the MIDI it will become.
--
-- This module is data only: it never sends. part_messages.lua turns a chosen
-- voice into events, the same way it does for every other control.

local M = {}

-- Where the .reabank files live. Resolved from this file's own path so an
-- installed copy finds them beside itself, exactly as the editor modules
-- resolve each other.
local SCRIPT_DIR = ({ reaper.get_action_context() })[2]:match('^(.*[/\\])') or ''

-- The four instrument maps, in the order the hardware lists them: oldest
-- first, so the SC-8850's own map is last and nearest the user's thumb.
--
-- A map is selected by Bank Select LSB, which is why each file's Bank lines
-- carry a different second number -- SC-55 is 1, SC-88 is 2, SC-88Pro is 3
-- and SC-8850 is 4 (manual p.69). The SC-8850 can sound any of them, which
-- is what makes the map a real choice rather than a historical note: the
-- older maps are how a sequence written for an older module plays back
-- correctly.
--
-- Each map has a tone file and a drum file. A Part using a drum map selects
-- from the drum file and a normal Part from the tone file, and the two are
-- never merged -- Bank 0 PC 0 means Piano 1 in one and STANDARD 1 in the
-- other.
local MAPS = {
  { name = 'SC-55',    lsb = 1,
    tones = 'SC-55.reabank',    drums = 'SC-55-Drums.reabank' },
  { name = 'SC-88',    lsb = 2,
    tones = 'SC-88.reabank',    drums = 'SC-88-Drums.reabank' },
  { name = 'SC-88Pro', lsb = 3,
    tones = 'SC-88Pro.reabank', drums = 'SC-88Pro-Drums.reabank' },
  { name = 'SC-8850',  lsb = 4,
    tones = 'SC-8850.reabank',  drums = 'SC-8850-Drums.reabank' },
}

M.MAPS = MAPS

-- Parse one .reabank's text into an ordered bank list.
--
-- Returns banks as { msb, lsb, name, voices = { { pc, name }, ... } }, in
-- file order. Order is kept rather than sorted because the file already
-- lists Capital Tones first and the variations after, which is the order a
-- user of the hardware expects to scroll through.
--
-- Unparseable lines are skipped rather than raising: a .reabank is a file a
-- user may edit or replace, and one bad line should cost that line, not the
-- whole voice list.
function M.parse(text)
  local banks, bank = {}, nil
  for line in text:gmatch('[^\r\n]+') do
    -- Comments and blanks carry nothing.
    if not line:match('^%s*;') and not line:match('^%s*$') then
      local msb, lsb, name = line:match('^Bank%s+(%d+)%s+(%d+)%s+(.-)%s*$')
      if msb then
        bank = { msb = tonumber(msb), lsb = tonumber(lsb), name = name,
                 voices = {} }
        banks[#banks + 1] = bank
      else
        local pc, vname = line:match('^(%d+)%s+(.-)%s*$')
        -- A voice line before any Bank line has no bank to belong to, so it
        -- is dropped rather than invented a home for.
        if pc and bank then
          bank.voices[#bank.voices + 1] =
            { pc = tonumber(pc), name = vname }
        end
      end
    end
  end
  return banks
end

-- Read and parse one file, or return nil and why.
local function load_file(name)
  local path = SCRIPT_DIR .. name
  local f, err = io.open(path, 'r')
  if not f then return nil, err or ('cannot open ' .. path) end
  local text = f:read('a')
  f:close()
  return M.parse(text)
end

-- The parsed maps, loaded once on first use.
--
-- Lazy rather than at require time so a missing or unreadable file does not
-- stop the editor from opening: the voice list degrades to empty and every
-- other control still works.
local loaded, load_error

local function ensure_loaded()
  if loaded then return loaded end
  loaded = {}
  for _, map in ipairs(MAPS) do
    local entry = { [false] = {}, [true] = {} }
    for _, kind in ipairs({ { false, map.tones }, { true, map.drums } }) do
      local banks, err = load_file(kind[2])
      if banks then
        entry[kind[1]] = banks
      else
        load_error = err
      end
    end
    loaded[map.lsb] = entry
  end
  return loaded
end

-- The map one Bank Select LSB selects, or nil when it selects none.
function M.map_of(lsb)
  for _, map in ipairs(MAPS) do
    if map.lsb == lsb then return map end
  end
  return nil
end

-- Every bank of one map, for one kind of Part.
--
-- `lsb` names the map. An unknown map has no banks rather than falling back
-- to a different one: a voice list from the wrong map would name sounds the
-- selected map does not have.
function M.banks(drum, lsb)
  local map = ensure_loaded()[lsb or M.DEFAULT_LSB]
  if not map then return {} end
  return map[drum and true or false]
end

-- Why the voice list is empty, when it is. nil once every file has loaded.
function M.error() ensure_loaded() return load_error end

-- The name of one voice, or nil when that address names nothing.
--
-- Looked up rather than indexed because the maps are sparse: bank 1 of the
-- tone map jumps from PC 2 to PC 5, and a table indexed by PC would report a
-- voice at 3 and 4 that the hardware does not have.
function M.name(drum, msb, lsb, pc)
  for _, bank in ipairs(M.banks(drum, lsb)) do
    if bank.msb == msb and bank.lsb == lsb then
      for _, v in ipairs(bank.voices) do
        if v.pc == pc then return v.name end
      end
      return nil
    end
  end
  return nil
end

-- The SC-8850's instrument categories.
--
-- Roland's own, from the GM 2 Instrument List (manual p.213-214), which
-- prints the tone table under these headings. They are the categories the
-- hardware's own INSTRUMENT display groups by, so a user hunting for a sound
-- looks under the same name here as on the front panel.
--
-- `first` is the 1-BASED program number each category starts at, exactly as
-- the manual prints it; a category runs to the start of the next. Stored as
-- the manual gives it and converted at lookup, so this table can be checked
-- against the page without doing arithmetic in your head.
local CATEGORIES = {
  { first = 1,   name = 'Piano' },
  { first = 9,   name = 'Chromatic Percussion' },
  { first = 17,  name = 'Organ' },
  { first = 25,  name = 'Guitar' },
  { first = 33,  name = 'Bass' },
  { first = 41,  name = 'Orchestra' },
  { first = 49,  name = 'Ensemble' },
  { first = 57,  name = 'Brass' },
  { first = 65,  name = 'Reed' },
  { first = 73,  name = 'Pipe' },
  { first = 81,  name = 'Synth Lead' },
  { first = 89,  name = 'Synth Pad' },
  { first = 97,  name = 'Synth SFX' },
  { first = 105, name = 'Ethnic Misc' },
  { first = 113, name = 'Percussive' },
  { first = 121, name = 'SFX' },
}

M.CATEGORIES = CATEGORIES

-- The category a program number belongs to.
--
-- `pc` is zero-based, as it is on the wire and in the .reabank files, so it
-- is shifted once here to meet the manual's 1-based table.
function M.category(pc)
  local n = pc + 1
  local found = CATEGORIES[1].name
  for _, c in ipairs(CATEGORIES) do
    if n >= c.first then found = c.name else break end
  end
  return found
end

-- Every voice of one map, grouped into the categories above.
--
-- Returns { { name = <category>, voices = { { pc, name, bank } ... } } ... }
-- in category order, with empty categories dropped. Each voice carries the
-- bank it came from, because the same program number appears in many banks
-- and the bank is what tells two same-named variations apart.
--
-- The drum map is not categorised: its Bank 0 holds drum SETS, not melodic
-- instruments, and the GM program families do not describe them. It comes
-- back as a single group named for its bank.
function M.by_category(drum, lsb)
  local banks = M.banks(drum, lsb)
  if drum then
    local voices = {}
    for _, bank in ipairs(banks) do
      for _, v in ipairs(bank.voices) do
        voices[#voices + 1] = { pc = v.pc, name = v.name, bank = bank }
      end
    end
    return { { name = 'Drum Sets', voices = voices } }
  end

  local by_name, order = {}, {}
  for _, c in ipairs(CATEGORIES) do
    by_name[c.name] = { name = c.name, voices = {} }
    order[#order + 1] = by_name[c.name]
  end

  for _, bank in ipairs(banks) do
    for _, v in ipairs(bank.voices) do
      local group = by_name[M.category(v.pc)]
      group.voices[#group.voices + 1] =
        { pc = v.pc, name = v.name, bank = bank }
    end
  end

  local out = {}
  for _, group in ipairs(order) do
    if #group.voices > 0 then out[#out + 1] = group end
  end

  -- Mark the few voices whose name alone is ambiguous.
  --
  -- Almost every name is unique inside its category, so printing the bank on
  -- every row is noise that pushes the names themselves off the edge. The
  -- handful that DO repeat -- four of the SC-8850's 1518 -- still need it,
  -- because two rows reading "Trumpet" with no way to tell them apart is
  -- worse than a suffix nobody asked for.
  for _, group in ipairs(out) do
    local seen = {}
    for _, v in ipairs(group.voices) do
      local first = seen[v.name]
      if first then
        first.ambiguous, v.ambiguous = true, true
      else
        seen[v.name] = v
      end
    end
  end

  return out
end

-- The power-on address of a Part.
--
-- Bank 0 / LSB 4 / PC 0 in both maps, which the manual gives as the reset
-- state: every Part is a Grand Piano and Part 10 is the drum Part. The LSB
-- is 4 because that is the SC-8850's own map -- the reabank files name it in
-- their Bank lines and the hardware selects the 8850 tone set with it.
M.DEFAULT_MSB, M.DEFAULT_LSB, M.DEFAULT_PC = 0, 4, 0

-- Whether a Part is a drum Part at power-on. Part 10 only, per the manual's
-- USE FOR RHYTHM PART default (40 1x 15: MAP1 at x=0, OFF elsewhere).
function M.drum_at_power_on(part) return part == 10 end

return M
