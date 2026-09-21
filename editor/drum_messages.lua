-- Canonical drum values to wire bytes, for the PAGER Part Editor.
--
-- The only place a drum value becomes MIDI. Everything upstream -- the panel,
-- the pending snapshot, the session state -- speaks the canonical vocabulary
-- drum_params.lua defines: Pan is -64..+63, not 0..127. The +64 offset lives
-- here and nowhere else, so a stored value can never be mistaken for a byte
-- that happens to look like it.
--
-- Unlike part_messages.lua there is no encoding choice to make. Every drum
-- control is a Roland DT1 write to 41 mp rr, always -- the Part Editor's
-- `Use SysEx?` setting does not reach these controls, because there is no CC
-- or RPN form of a drum map parameter to fall back to (manual pp.70-72).
--
-- One entry point, `encode`, returns an ordered list of typed events in the
-- same shape part_messages.lua produces, so the same list feeds hardware
-- preview and take insertion and the two cannot drift apart:
--
--   { kind = 'sysex', payload = '<bytes without F0/F7>', addr = { a, b, c } }
--
-- `addr` travels with the event so insertion can match a previous write by
-- its complete three-byte drum address rather than by finding some SysEx on
-- the tick.
--
-- This module makes no REAPER calls and holds no state.

local GS = require 'gs_sysex'
local D = require 'drum_params'

local M = {}

-- value conversions ---------------------------------------------------------

-- Pan is the one row whose canonical value is not its wire byte. The field
-- runs 00H..40H..7FH for Random..centre..hard right (manual p.240), so the
-- canonical -64..+63 maps exactly by adding 64 -- and -64 lands on Random,
-- which is a real per-instrument setting here rather than an endpoint
-- collision the way it is for a Part's Pan.
local function pan_byte(v) return math.floor(v + 0.5) + 64 end

-- Pitch is PLAY NOTE NUMBER: the wire field is an absolute sample pitch
-- 00..7F, while the panel and the factory data speak the relative form the
-- hardware's own editor shows, centred on a neutral 60. Adding it back is the
-- exact inverse of what drum_params does when it seeds a note.
local function pitch_byte(v) return math.floor(v + 0.5) + D.PITCH_NEUTRAL end

-- Everything else is sent as the number it already is.
local function plain_byte(v) return math.floor(v + 0.5) end

local CONV = { pan = pan_byte, pitch = pitch_byte }

M._conv = { pan_byte = pan_byte, pitch_byte = pitch_byte,
            plain_byte = plain_byte }

-- entry point ---------------------------------------------------------------

-- Encode one drum control's settled canonical value as an ordered event list.
--
--   id     a drum_params row id
--   value  the canonical value, which must already be inside that row's range
--   mode   1 or 2 -- WHICH MAP, never a Part number
--   note   the MIDI note number, 0..127
--
-- Validation happens BEFORE any byte conversion. An out-of-range value is an
-- error rather than something masked into range: `128 & 0x7F` is 0, which is
-- a real value at a real address, so masking turns a caller's mistake into a
-- silent wrong edit on the hardware.
--
-- There is no `part` and no `use_sysex` argument by design. A drum value
-- belongs to the map and every Part playing that map sees it, so a Part
-- cannot be part of the identity; and the encoding is DT1 in every mode.
function M.encode(id, value, mode, note)
  local p = D.BY_ID[id]
  assert(p, 'unknown drum parameter: ' .. tostring(id))
  assert(D.valid_mode(mode), 'drum map must be 1 or 2, got ' .. tostring(mode))
  assert(D.valid_note(note),
         'drum note must be an integer 0..127, got ' .. tostring(note))

  local v = D.validate(p, value)
  assert(v ~= nil, ('%s: value %s is outside %d..%d')
    :format(id, tostring(value), p.min, p.max))

  local addr = GS.drum_param_addr(mode, p.nibble, note)
  local data = (CONV[id] or plain_byte)(v)

  return { {
    kind = 'sysex',
    payload = GS.dt1({ addr[1], addr[2], addr[3], data }),
    addr = addr,
  } }
end

-- The DT1 address one control occupies on one map and note.
--
-- Exposed so insertion can ask what to look for without encoding a value
-- first. It is the same address encode() attaches to its event, from the same
-- helper, so the two cannot disagree.
function M.addr_of(id, mode, note)
  local p = D.BY_ID[id]
  assert(p, 'unknown drum parameter: ' .. tostring(id))
  return GS.drum_param_addr(mode, p.nibble, note)
end

return M
