-- Part control metadata for the PAGER Part Editor.
--
-- One row per control the panel shows, in the order the panel shows them.
-- This file is data only: it says what a control IS -- its canonical range,
-- its default, how a value is displayed, and which wire encodings exist for
-- it -- and never how a value becomes bytes. That is part_messages.lua, which
-- reads these rows and is the only place the translation happens.
--
-- Canonical values are musical, not wire bytes. Cutoff is -64..+63, not
-- 0..127; Tuning Offset is Hertz, not a nibblized pair. Every offset and
-- nibblization belongs to the encoder, so the UI, the session state and the
-- pending snapshot all speak one vocabulary and a stored value cannot be
-- misread as a byte.
--
-- Sources: SC-8850 manual pp.226-229 (CC and RPN definitions), pp.237-240
-- (the per-Part address map, data ranges and defaults), pp.54-55 and 65-67
-- (user-facing ranges). Cross-checked against
-- docs/research-part-editor-midi-mapping.md.

-- How `Use SysEx? off` is encoded.
--
--   'cc'   a single Control Change
--   'rpn'  an ordered RPN run: selector, Data Entry, RPN Null
--   'dt1'  a Roland DT1 write EVEN WITH SysEx off -- see FALLBACK below
--
-- Three controls carry native = 'dt1'. EQ On/Off and Tuning Offset have no
-- CC, RPN or NRPN at all (manual pp.238, 55), so there is nothing to fall
-- back from. Pitch Key does have RPN 2 over the same coarse-tuning range, but
-- the manual never identifies RPN 2 as the stored PITCH KEY SHIFT Part
-- parameter, so this editor does not claim they are the same field.
local CC, RPN, DT1 = 'cc', 'rpn', 'dt1'

-- Display rules. The panel formats a canonical value by `display`; the
-- encoder ignores it entirely.
--
--   'plain'   64            0..127 counts
--   'signed'  +20           relative tone modifiers, which read as offsets
--   'pan'     L63 / C / R41
--   'semi'    +7 st
--   'hz'      -3.4 Hz
--   'cents'   +50 cents
--   'switch'  Off / On
local M = {}

-- Groups, in panel order. The panel draws these as labelled sections; the
-- order here is the order on screen, and the Sound Canvas VA Tone Editor's
-- grouping rather than the old GSAE table's.
M.GROUPS = {
  'Sends and Mix',
  'Filter',
  'Envelope',
  'Tuning',
  'Vibrato',
  'Switches and Performance',
}

-- Every row, keyed by `id` and ordered as listed.
--
-- id       stable key for session state and the pending snapshot; never shown
-- name     the label on screen
-- group    one of M.GROUPS
-- min/max  inclusive canonical bounds
-- default  the documented power-on value, and what double-click returns to
-- step     slider granularity; only Tuning Offset is not 1
-- display  one of the rules above
-- native   CC, RPN or DT1 -- what `Use SysEx? off` sends
-- cc       controller number, when native == CC
-- rpn      RPN number, when native == RPN
-- rpn_fine true when the RPN uses CC38 as well as CC6 (14-bit Data Entry)
-- dt1      low address byte on the 40 1x block, unless dt1_block says otherwise
-- dt1_len  how many consecutive address bytes the DT1 value occupies
-- dt1_block 'param' (40 1x, the default), 'bend' (40 2x) or 'switch' (40 4x)
M.PARAMS = {
  -- sends and mix ------------------------------------------------------------
  { id = 'level', name = 'Level', group = 'Sends and Mix',
    min = 0, max = 127, default = 100, display = 'plain',
    native = CC, cc = 7, dt1 = 0x19 },

  -- Pan is the one control whose two encodings are not byte-identical. CC10
  -- defines 0 as hard left, but DT1 value 0 means Random, and ordinary left
  -- starts at 1 (manual p.226 against p.238). The canonical range is the
  -- musical one, L63..C..R63, and the encoder resolves the endpoint; Random
  -- is deliberately not reachable from this panel.
  { id = 'pan', name = 'Pan', group = 'Sends and Mix',
    min = -63, max = 63, default = 0, display = 'pan',
    native = CC, cc = 10, dt1 = 0x1C },

  { id = 'reverb', name = 'Reverb Send', group = 'Sends and Mix',
    min = 0, max = 127, default = 40, display = 'plain',
    native = CC, cc = 91, dt1 = 0x22 },
  { id = 'chorus', name = 'Chorus Send', group = 'Sends and Mix',
    min = 0, max = 127, default = 0, display = 'plain',
    native = CC, cc = 93, dt1 = 0x21 },
  { id = 'delay', name = 'Delay Send', group = 'Sends and Mix',
    min = 0, max = 127, default = 0, display = 'plain',
    native = CC, cc = 94, dt1 = 0x2C },

  -- filter -------------------------------------------------------------------
  { id = 'cutoff', name = 'Cutoff', group = 'Filter',
    min = -64, max = 63, default = 0, display = 'signed',
    native = CC, cc = 74, dt1 = 0x32 },
  { id = 'resonance', name = 'Resonance', group = 'Filter',
    min = -64, max = 63, default = 0, display = 'signed',
    native = CC, cc = 71, dt1 = 0x33 },

  -- envelope -----------------------------------------------------------------
  { id = 'attack', name = 'Attack', group = 'Envelope',
    min = -64, max = 63, default = 0, display = 'signed',
    native = CC, cc = 73, dt1 = 0x34 },
  { id = 'decay', name = 'Decay', group = 'Envelope',
    min = -64, max = 63, default = 0, display = 'signed',
    native = CC, cc = 75, dt1 = 0x35 },
  { id = 'release', name = 'Release', group = 'Envelope',
    min = -64, max = 63, default = 0, display = 'signed',
    native = CC, cc = 72, dt1 = 0x36 },

  -- tuning -------------------------------------------------------------------
  -- Offset and Fine are different controls, not two views of one. Offset is
  -- the VA Offset knob: fixed Hertz, SysEx-only, stored as tenths of a Hertz
  -- across two nibblized bytes. Fine is cents and has both an RPN 1 form and
  -- a DT1 form (manual pp.55, 228, 238).
  { id = 'tuning_offset', name = 'Tuning Offset', group = 'Tuning',
    min = -12.0, max = 12.0, default = 0.0, step = 0.1, display = 'hz',
    native = DT1, dt1 = 0x17, dt1_len = 2 },
  { id = 'fine_tune', name = 'Fine Tune', group = 'Tuning',
    min = -100, max = 99.99, default = 0, display = 'cents',
    native = RPN, rpn = 1, rpn_fine = true, dt1 = 0x2A, dt1_len = 2 },

  -- vibrato ------------------------------------------------------------------
  { id = 'vib_rate', name = 'Rate', group = 'Vibrato',
    min = -64, max = 63, default = 0, display = 'signed',
    native = CC, cc = 76, dt1 = 0x30 },
  { id = 'vib_depth', name = 'Depth', group = 'Vibrato',
    min = -64, max = 63, default = 0, display = 'signed',
    native = CC, cc = 77, dt1 = 0x31 },
  { id = 'vib_delay', name = 'Delay', group = 'Vibrato',
    min = -64, max = 63, default = 0, display = 'signed',
    native = CC, cc = 78, dt1 = 0x37 },

  -- switches and performance -------------------------------------------------
  { id = 'eq', name = 'EQ', group = 'Switches and Performance',
    min = 0, max = 1, default = 1, display = 'switch',
    native = DT1, dt1 = 0x20, dt1_block = 'switch' },

  -- Portamento stays CC in both modes. The DT1 Rx. PORTAMENTO field at
  -- 40 1x 10 enables RECEIPT of portamento messages; it is not the audible
  -- current state of Portamento On/Off, and writing it would silently mean
  -- something else (manual pp.227, 238).
  { id = 'porta', name = 'Portamento', group = 'Switches and Performance',
    min = 0, max = 1, default = 0, display = 'switch',
    native = CC, cc = 65 },
  { id = 'porta_time', name = 'Portamento Time', group = 'Switches and Performance',
    min = 0, max = 127, default = 0, display = 'plain',
    native = CC, cc = 5 },

  { id = 'pitch_key', name = 'Pitch Key', group = 'Switches and Performance',
    min = -24, max = 24, default = 0, display = 'semi',
    native = DT1, dt1 = 0x16 },
  { id = 'bend_range', name = 'Bend Range', group = 'Switches and Performance',
    min = 0, max = 24, default = 2, display = 'semi',
    native = RPN, rpn = 0, dt1 = 0x10, dt1_block = 'bend' },
}

M.CC, M.RPN, M.DT1 = CC, RPN, DT1

-- id -> row, so the encoder, the pending snapshot and the session restore can
-- all name a control by its stable key rather than its panel position.
M.BY_ID = {}
for _, p in ipairs(M.PARAMS) do
  assert(not M.BY_ID[p.id], 'duplicate part param id: ' .. p.id)
  M.BY_ID[p.id] = p
end

-- Every row must be internally consistent. These run at require time because
-- a row that says `native = CC` with no controller number is a typo that
-- would otherwise surface as a nil arithmetic error inside the encoder, one
-- layer away from the mistake.
for _, p in ipairs(M.PARAMS) do
  assert(p.min <= p.default and p.default <= p.max,
         p.id .. ': default outside its own range')
  assert(p.native == CC or p.native == RPN or p.native == DT1,
         p.id .. ': unknown native encoding')
  if p.native == CC then assert(p.cc, p.id .. ': CC row without a controller') end
  if p.native == RPN then assert(p.rpn, p.id .. ': RPN row without an RPN number') end
  if p.native == DT1 then assert(p.dt1, p.id .. ': DT1 row without an address') end
  local group_ok = false
  for _, g in ipairs(M.GROUPS) do if g == p.group then group_ok = true break end end
  assert(group_ok, p.id .. ': unknown group ' .. tostring(p.group))
end

-- Whether a control can be written as SysEx at all. Portamento and Portamento
-- Time cannot: the manual documents no musical-state DT1 field for either, so
-- `Use SysEx? on` leaves them on CC rather than inventing an address.
function M.has_sysex(p) return p.dt1 ~= nil end

-- Clamp a canonical value into a row's range, or return nil when it is not a
-- number at all. Session restore drops what this rejects and keeps the
-- default, per the design's invalid-saved-value rule.
function M.validate(p, v)
  if type(v) ~= 'number' or v ~= v then return nil end
  if v < p.min or v > p.max then return nil end
  return v
end

return M
