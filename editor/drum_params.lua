-- Drum control metadata for the PAGER Part Editor.
--
-- One row per per-note drum control, in the order the panel shows them. Data
-- only, exactly as part_params.lua is: this says what a control IS -- its
-- canonical range, how it is displayed, and which address nibble it lives at
-- -- and never how a value becomes bytes. That is drum_messages.lua.
--
-- What makes these rows different from the Part rows is WHO OWNS THE VALUE.
-- A Part parameter belongs to one Part. A drum parameter belongs to a MAP:
-- the SC-8850 holds two drum maps, any number of Parts may play either, and
-- every Part on a map hears the same per-note values (manual p.55). So the
-- identity of a drum value is (map, note, parameter) and a Part is nowhere in
-- it -- which is why nothing here mentions one.
--
-- Canonical values are musical, not wire bytes. Pan is -64..+63, not 0..127;
-- the +64 offset belongs to the encoder, so the UI, the session state and the
-- pending snapshot all speak one vocabulary.
--
-- Sources: SC-8850 manual pp.70-72 (the Drum Setup parameters and their
-- user-facing ranges) and p.240 (the 41 mp rr address map).

local M = {}

-- Display rules, the subset the drum panel needs. Numbers only: the plan
-- fixes a numeric panel with no note names, instrument names or preset data,
-- so there is no 'pan' rule here -- Pan shows its canonical -64..63.
--
--   'plain'   64        a number, as-is
--   'switch'  Off / On
local PLAIN, SWITCH = 'plain', 'switch'

-- Every row, keyed by `id` and ordered as the panel lists them.
--
-- id       stable key for session state and the pending snapshot; never shown
-- name     the label on screen
-- min/max  inclusive canonical bounds
-- display  one of the rules above
-- nibble   the parameter nibble in 41 mp rr -- the `p`
--
-- The order below is the PANEL's, not the protocol's: Rx Note Off holds the
-- lower nibble (7) but reads better after Rx Note On, so the two are listed
-- the way they are used rather than the way they are addressed.
M.PARAMS = {
  -- PLAY NOTE NUMBER (manual p.240), which the panel shows as a relative
  -- pitch rather than as the absolute note the wire field holds.
  --
  -- The wire field is 00..7F, an absolute sample pitch. The factory data and
  -- the hardware's own editor both treat 60 as neutral and display the
  -- difference: the toms all store 53 and read as -7, the hi and low agogos
  -- store 63 and 58 and read as +3 and -2. So the canonical range is the
  -- wire range shifted by that neutral: 0..127 becomes -60..+67.
  --
  -- Asymmetric on purpose. Clamping it to a tidy -64..+63 would make the top
  -- seven sample pitches unreachable and reject factory values that are
  -- perfectly legal on the device.
  { id = 'pitch', name = 'Pitch',
    min = -60, max = 67, display = PLAIN, nibble = 1 },
  { id = 'level', name = 'Level',
    min = 0, max = 127, display = PLAIN, nibble = 2 },

  -- Assign Group is a number, not a range of loudness: instruments sharing a
  -- non-zero group cut each other off, which is how a closed hi-hat stops an
  -- open one. Numeric 0 means Non, and the panel shows the number rather
  -- than inventing a name for it.
  { id = 'assign_group', name = 'Assign Group',
    min = 0, max = 127, display = PLAIN, nibble = 3 },

  -- Pan's canonical range is -64..+63 and the wire value is that plus 64, so
  -- -64 is the hardware's Random setting and 0 is centre (manual p.240).
  -- Unlike the Part Pan row, -64 is reachable here: the drum field has no
  -- second encoding to disagree with, and Random is a real per-instrument
  -- setting rather than an endpoint collision.
  { id = 'pan', name = 'Pan',
    min = -64, max = 63, display = PLAIN, nibble = 4 },

  { id = 'reverb', name = 'Reverb',
    min = 0, max = 127, display = PLAIN, nibble = 5 },
  { id = 'chorus', name = 'Chorus',
    min = 0, max = 127, display = PLAIN, nibble = 6 },

  -- The manual notes that Chorus and Delay cannot both be active for one
  -- drum instrument -- whichever was written last wins on the hardware. Both
  -- numeric values are kept here regardless, and only the control the user
  -- touched is ever sent: zeroing the other one silently would discard an
  -- edit the user made and never asked to undo.
  { id = 'delay', name = 'Delay',
    min = 0, max = 127, display = PLAIN, nibble = 9 },

  { id = 'rx_note_on', name = 'Rx Note On',
    min = 0, max = 1, display = SWITCH, nibble = 8 },
  { id = 'rx_note_off', name = 'Rx Note Off',
    min = 0, max = 1, display = SWITCH, nibble = 7 },
}

M.PLAIN, M.SWITCH = PLAIN, SWITCH

-- id -> row, so the encoder, the pending snapshot and the session restore can
-- all name a control by its stable key rather than its panel position.
M.BY_ID = {}
for _, p in ipairs(M.PARAMS) do
  assert(not M.BY_ID[p.id], 'duplicate drum param id: ' .. p.id)
  M.BY_ID[p.id] = p
end

-- Every row must be internally consistent, checked at require time. Two rows
-- sharing a nibble would write to the same hardware field and BOTH would
-- appear to work, which is exactly the kind of mistake that survives a
-- hardware test.
do
  local by_nibble = {}
  for _, p in ipairs(M.PARAMS) do
    assert(p.min < p.max, p.id .. ': empty range')
    assert(p.display == PLAIN or p.display == SWITCH,
           p.id .. ': unknown display rule')
    assert(type(p.nibble) == 'number' and p.nibble >= 1 and p.nibble <= 9,
           p.id .. ': nibble must be 1..9')
    assert(not by_nibble[p.nibble],
           p.id .. ': nibble ' .. p.nibble .. ' already used by ' ..
           tostring(by_nibble[p.nibble]))
    by_nibble[p.nibble] = p.id
    if p.display == SWITCH then
      assert(p.min == 0 and p.max == 1, p.id .. ': a switch must be 0..1')
    end
  end
end

-- validation ------------------------------------------------------------------

-- Which drum map, 1 or 2. Never a Part number: a value belongs to the map.
function M.valid_mode(mode)
  return mode == 1 or mode == 2
end

-- A MIDI note number. Integer, because it is the third address byte and a
-- fraction there is not an address at all.
function M.valid_note(note)
  return type(note) == 'number' and note == note
     and note >= 0 and note <= 127 and note == math.floor(note)
end

-- Clamp-free validation, matching part_params.validate: a value outside a
-- row's range is DROPPED rather than moved to an endpoint. A clamped value
-- looks deliberate on screen and the user cannot see which field came back
-- wrong.
function M.validate(p, v)
  if type(v) ~= 'number' or v ~= v then return nil end
  if v < p.min or v > p.max then return nil end
  return v
end

-- factory defaults ---------------------------------------------------------------

-- The SC-8850's own per-note values for every factory kit, extracted from the
-- GSAE decompilation and verified against the hardware panel. See
-- scripts/extract_drum_defaults.py for how the field order was recovered.
local Defaults = require 'drum_defaults'

M.PITCH_NEUTRAL = Defaults.PITCH_NEUTRAL

-- The stored bytes are not the canonical vocabulary the rest of the editor
-- speaks, so two fields are converted on the way in. Both conversions are the
-- inverse of what drum_messages.lua does on the way out, which is what keeps a
-- seeded value and an edited one indistinguishable downstream.

-- Pan: the wire field is 0 = Random, 1..64..127 = left..centre..right, and
-- canonical Pan is -64..+63 with -64 meaning Random. So 0 maps to -64 and
-- everything else is the byte minus 64.
local function pan_from_byte(b)
  if b == 0 then return -64 end
  return b - 64
end

-- Pitch: PLAY NOTE NUMBER is stored against a neutral 60 rather than centred
-- on 64, so the panel shows `stored - 60`. Note 22 of STANDARD 1 stores 72 and
-- the hardware panel reads +12.
local function pitch_from_byte(b)
  return b - Defaults.PITCH_NEUTRAL
end

local FROM_BYTE = { pan = pan_from_byte, pitch = pitch_from_byte }

-- The generic fallback, used for a note the factory tables do not cover: an
-- unknown map or kit, or a User Drum Set.
--
-- Deliberately bland rather than clever. It is not a claim about what the
-- hardware holds -- it is what the editor shows when it has nothing better,
-- and Pitch 0 means "as written" rather than some other instrument's tuning.
local function generic_seed()
  return {
    pitch = 0, level = 127, assign_group = 0, pan = 0,
    reverb = 0, chorus = 0, delay = 0,
    rx_note_on = 1, rx_note_off = 0,
  }
end

-- The stored row for one note, or nil when the tables do not cover it.
--
-- A kit is (Bank LSB, program change), never a program change alone: the LSB
-- selects the instrument map, so PC 0 is STANDARD on the SC-55, STANDARD 1 on
-- the SC-88 and a different STANDARD 1 again on the SC-8850.
local function stored_row(map, kit, note)
  local kits = map ~= nil and Defaults.MAPS[map] or nil
  local notes = kits and kits[kit]
  return notes and notes[note]
end

-- What an unseen note starts at, in canonical units.
--
--   note  the MIDI note number, 0..127
--   kit   the drum kit's program change, or nil
--   map   the Bank LSB naming the instrument map, or nil
--
-- With a kit the factory tables cover, these are the hardware's OWN values
-- for that instrument -- which are not uniform: Concert Snare ships with
-- Reverb 50 and MC-500 Beep 1 with Reverb 0 and Pitch +12, and the hi-hats
-- share an Assign Group so they cut each other off. Seeding every note the
-- same way would misreport all of that.
--
-- This is still not a live read of the device. No RQ1 query is made, so a
-- note the user has already changed on the hardware reads as its factory
-- value here. It is the factory table, not the current state.
--
-- All nine parameters come from the table, Chorus and Delay included. Delay
-- is 0 throughout the factory kits and Chorus is 0 throughout the SC-8850
-- map, but both are extracted values rather than assumptions -- a kit whose
-- table said otherwise would be carried through.
--
-- A fresh table per call: two notes sharing one would make editing note 0
-- silently change note 60.
function M.seed_values(note, kit, map)
  assert(M.valid_note(note), 'drum note must be an integer 0..127')

  local values = generic_seed()
  local stored = stored_row(map, kit, note)
  if not stored then return values end

  for i, id in ipairs(Defaults.FIELDS) do
    local conv = FROM_BYTE[id]
    local v = stored[i]
    values[id] = conv and conv(v) or v
  end
  return values
end

-- Whether the factory tables cover one kit of one map, which is what the
-- panel needs before claiming a value came from the hardware's own defaults.
function M.has_kit(kit, map)
  local kits = map ~= nil and Defaults.MAPS[map] or nil
  return kits ~= nil and kits[kit] ~= nil
end

-- The notes one factory kit defines, ascending, or nil when the tables do not
-- cover the kit. The Drum Overview draws these rows rather than all 128.
function M.kit_notes(kit, map)
  local kits = map ~= nil and Defaults.MAPS[map] or nil
  local notes = kits and kits[kit]
  if not notes then return nil end
  local out = {}
  for n in pairs(notes) do out[#out + 1] = n end
  table.sort(out)
  return out
end

-- [bank lsb] = { [program change] = name }, and the map names themselves.
M.KIT_NAMES = Defaults.KIT_NAMES
M.MAP_NAMES = Defaults.MAP_NAMES

return M
