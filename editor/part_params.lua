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
--   'enum'    one of `choices`, by index from `min`
--   'note'    C-1 .. G9, the manual's own names for 0..127
local M = {}

-- Rx Channel's choices: channels 1..16, then Off (wire 10H).
local RX_CHANNELS = {}
for i = 1, 16 do RX_CHANNELS[i] = tostring(i) end
RX_CHANNELS[17] = 'Off'

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
  'Keyboard',
  'Receive',
  'Scale Tuning',
  'Mod Wheel',
  'Pitch Bend',
  'Channel Aftertouch',
  'Poly Aftertouch',
  'CC1',
  'CC2',
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
-- dt1_offset added to the canonical value to make the DT1 byte, for the
--          generic single-byte rows: 0x40 for a centred field, -1 for Rx
--          Channel's 1-based channels. Absent means the value is the byte.
-- part_default  the power-on value is the Part's own number (Rx Channel);
--          `default` then holds Part 1's, and P.default_for resolves it
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

  -- 40 4x 21: which physical output the Part plays through (p.240; worked
  -- example on p.61: Part 1 to OUTPUT-2 is 40 41 21 01, checksum 5D).
  { id = 'output', name = 'Output Assign', group = 'Switches and Performance',
    min = 0, max = 3, default = 0, display = 'enum',
    choices = { 'Output 1', 'Output 2', 'Output 2L', 'Output 2R' },
    native = DT1, dt1 = 0x21, dt1_block = 'switch' },

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

  -- Mono/Poly is two controllers, not one: Mono is CC126 and Poly is CC127 00
  -- (manual p.229; the DT1 field at 40 1x 13 notes the same equivalence,
  -- p.238). `cc` is Poly and `cc_alt` is Mono, so Insert's removal matches
  -- a previous copy in either form. Both CCs also act as All Sounds Off and
  -- All Notes Off on the channel (p.229), so a change cuts sounding notes.
  { id = 'mono_poly', name = 'Mono/Poly', group = 'Switches and Performance',
    min = 0, max = 1, default = 1, display = 'enum',
    choices = { 'Mono', 'Poly' },
    native = CC, cc = 127, cc_alt = 126, dt1 = 0x13 },

  -- Which drum map this Part plays, if any. SysEx-only: the manual gives no
  -- CC or RPN for it (40 1x 15, p.238), so `Use SysEx? off` has nothing to
  -- fall back to and this row is DT1 in both modes.
  --
  -- The SC-8850 holds two drum maps at once and any Part can use either, so
  -- this is three states rather than a switch. Part 10 is MAP1 at power-on
  -- and every other Part is OFF.
  { id = 'rhythm', name = 'Use For Rhythm', group = 'Switches and Performance',
    min = 0, max = 2, default = 0, display = 'enum',
    choices = { 'None', 'DRUM 1', 'DRUM 2' },
    native = DT1, dt1 = 0x15 },

  { id = 'pitch_key', name = 'Pitch Key', group = 'Switches and Performance',
    min = -24, max = 24, default = 0, display = 'semi',
    native = DT1, dt1 = 0x16 },
  { id = 'bend_range', name = 'Bend Range', group = 'Switches and Performance',
    min = 0, max = 24, default = 2, display = 'semi',
    native = RPN, rpn = 0, dt1 = 0x10, dt1_block = 'bend' },

  -- keyboard -----------------------------------------------------------------
  -- All SysEx-only (manual pp.237-238): none has a CC or RPN.

  -- 40 1x 02: 00..0F receive on channel 1..16, 10H is Off. Defaults to the
  -- Part's own number. Moving it means the Part no longer hears the CCs this
  -- editor sends on the Part's channel -- only DT1 writes, which address the
  -- Part directly, still reach it.
  { id = 'rx_channel', name = 'Rx Channel', group = 'Keyboard',
    min = 1, max = 17, default = 1, part_default = true, display = 'enum',
    choices = RX_CHANNELS, native = DT1, dt1 = 0x02, dt1_offset = -1 },

  -- 40 1x 14: how a repeated note on the same channel overlaps itself.
  -- Limited-Multi is the default on the SC-8850/88Pro/88 maps (p.238).
  { id = 'assign_mode', name = 'Assign Mode', group = 'Keyboard',
    min = 0, max = 2, default = 1, display = 'enum',
    choices = { 'Single', 'Limited-Multi', 'Full-Multi' },
    native = DT1, dt1 = 0x14 },

  { id = 'vel_depth', name = 'Velocity Depth', group = 'Keyboard',
    min = 0, max = 127, default = 64, display = 'plain',
    native = DT1, dt1 = 0x1A },
  { id = 'vel_offset', name = 'Velocity Offset', group = 'Keyboard',
    min = 0, max = 127, default = 64, display = 'plain',
    native = DT1, dt1 = 0x1B },

  { id = 'key_low', name = 'Key Range Low', group = 'Keyboard',
    min = 0, max = 127, default = 0, display = 'note',
    native = DT1, dt1 = 0x1D },
  { id = 'key_high', name = 'Key Range High', group = 'Keyboard',
    min = 0, max = 127, default = 127, display = 'note',
    native = DT1, dt1 = 0x1E },
}

-- Receive switches, 40 1x 03..12, 23, 24 (pp.237-238): whether the Part
-- listens to each kind of message at all. All On at power-on except Rx NRPN,
-- which the table lists Off -- a GS Reset turns it On, GM1/GM2 System On
-- turns it Off again. Rx Portamento is the receive gate for CC65, not the
-- audible Portamento switch on the Common page.
local RECEIVE = {
  { 'rx_bend',        'Rx Pitch Bend',        0x03, 1 },
  { 'rx_caf',         'Rx Ch Pressure',       0x04, 1 },
  { 'rx_pc',          'Rx Program Change',    0x05, 1 },
  { 'rx_cc',          'Rx Control Change',    0x06, 1 },
  { 'rx_paf',         'Rx Poly Pressure',     0x07, 1 },
  { 'rx_note',        'Rx Note Message',      0x08, 1 },
  { 'rx_rpn',         'Rx RPN',               0x09, 1 },
  { 'rx_nrpn',        'Rx NRPN',              0x0A, 0 },
  { 'rx_mod',         'Rx Modulation',        0x0B, 1 },
  { 'rx_volume',      'Rx Volume',            0x0C, 1 },
  { 'rx_pan',         'Rx Panpot',            0x0D, 1 },
  { 'rx_expression',  'Rx Expression',        0x0E, 1 },
  { 'rx_hold1',       'Rx Hold1',             0x0F, 1 },
  { 'rx_porta',       'Rx Portamento',        0x10, 1 },
  { 'rx_sostenuto',   'Rx Sostenuto',         0x11, 1 },
  { 'rx_soft',        'Rx Soft',              0x12, 1 },
  { 'rx_bank',        'Rx Bank Select',       0x23, 1 },
  { 'rx_bank_lsb',    'Rx Bank Select LSB',   0x24, 1 },
}
for _, r in ipairs(RECEIVE) do
  M.PARAMS[#M.PARAMS + 1] = {
    id = r[1], name = r[2], group = 'Receive', min = 0, max = 1,
    default = r[4], display = 'switch', native = DT1, dt1 = r[3],
  }
end

-- Scale Tuning, 40 1x 40..4B: one row per pitch class, C first, each
-- -64..+63 cents centred on 40H (manual p.238; the PDF's text layer shifts
-- the labels one row, but C is 40 and B is 4B -- twelve fields from 40).
local PITCH_CLASSES = { 'C', 'C#', 'D', 'D#', 'E', 'F',
                        'F#', 'G', 'G#', 'A', 'A#', 'B' }
for i, pc in ipairs(PITCH_CLASSES) do
  M.PARAMS[#M.PARAMS + 1] = {
    id = 'scale_' .. pc:lower():gsub('#', 's'), name = 'Scale ' .. pc,
    group = 'Scale Tuning', min = -64, max = 63, default = 0, display = 'cents',
    native = DT1, dt1 = 0x40 + i - 1, dt1_offset = 0x40,
  }
end

-- What each controller source drives, 40 2x (manual pp.239-240). Every
-- source has the same eleven destinations at the same offsets from its base.
-- Values are the raw steps, centred ones as -64..+63: the manual's units
-- (cents, %, Hz) are nominal, and a byte is what the hardware takes.
--
-- Bend's Pitch Control is Bend Range above, so it is not repeated.
local SOURCES = {
  { key = 'mod',  name = 'Mod',  group = 'Mod Wheel',          base = 0x00 },
  { key = 'bend', name = 'Bend', group = 'Pitch Bend',         base = 0x10 },
  { key = 'caf',  name = 'CAf',  group = 'Channel Aftertouch', base = 0x20 },
  { key = 'paf',  name = 'PAf',  group = 'Poly Aftertouch',    base = 0x30 },
  -- CC1 and CC2 are assignable: which controller each listens to is itself a
  -- Part parameter, 40 1x 1F / 20, CC#0..95, default 16 / 17 (p.238).
  { key = 'cc1',  name = 'CC1',  group = 'CC1',                base = 0x40,
    number_dt1 = 0x1F, number_default = 16 },
  { key = 'cc2',  name = 'CC2',  group = 'CC2',                base = 0x50,
    number_dt1 = 0x20, number_default = 17 },
}

-- The controller-number choices: CC#0..CC#95, index = controller number.
local CC_NUMBERS = {}
for n = 0, 95 do CC_NUMBERS[n + 1] = 'CC#' .. n end
local DESTINATIONS = {
  { key = 'pitch',      name = 'Pitch Control',    kind = 'semi' },
  { key = 'cutoff',     name = 'TVF Cutoff',       kind = 'signed' },
  { key = 'amp',        name = 'Amplitude',        kind = 'signed' },
  { key = 'lfo1_rate',  name = 'LFO1 Rate',        kind = 'signed' },
  { key = 'lfo1_pitch', name = 'LFO1 Pitch Depth', kind = 'depth' },
  { key = 'lfo1_tvf',   name = 'LFO1 TVF Depth',   kind = 'depth' },
  { key = 'lfo1_tva',   name = 'LFO1 TVA Depth',   kind = 'depth' },
  { key = 'lfo2_rate',  name = 'LFO2 Rate',        kind = 'signed' },
  { key = 'lfo2_pitch', name = 'LFO2 Pitch Depth', kind = 'depth' },
  { key = 'lfo2_tvf',   name = 'LFO2 TVF Depth',   kind = 'depth' },
  { key = 'lfo2_tva',   name = 'LFO2 TVA Depth',   kind = 'depth' },
}
-- Exposed for the panel's controller matrix, which lays these rows out as
-- destinations down and sources across, as GSAE's Controller Matrix does.
M.CONTROLLER_SOURCES, M.CONTROLLER_DESTINATIONS = SOURCES, DESTINATIONS

-- The row one matrix cell edits. Bend's Pitch Control is Bend Range.
function M.matrix_id(src_key, dst_key)
  if src_key == 'bend' and dst_key == 'pitch' then return 'bend_range' end
  return src_key .. '_' .. dst_key
end

for _, src in ipairs(SOURCES) do
  if src.number_dt1 then
    M.PARAMS[#M.PARAMS + 1] = {
      id = src.key .. '_number', name = src.name .. ' Controller',
      group = src.group, min = 0, max = 95, default = src.number_default,
      display = 'enum', choices = CC_NUMBERS,
      native = DT1, dt1 = src.number_dt1,
    }
  end
  for i, dst in ipairs(DESTINATIONS) do
    if not (src.key == 'bend' and dst.key == 'pitch') then
      local row = {
        id = src.key .. '_' .. dst.key, name = src.name .. ' ' .. dst.name,
        group = src.group, native = DT1, dt1 = src.base + i - 1,
        dt1_block = 'bend',
      }
      if dst.kind == 'semi' then
        row.min, row.max, row.display, row.dt1_offset = -24, 24, 'semi', 0x40
      elseif dst.kind == 'signed' then
        row.min, row.max, row.display, row.dt1_offset = -64, 63, 'signed', 0x40
      else
        row.min, row.max, row.display = 0, 127, 'plain'
      end
      row.default = 0
      -- The one non-zero depth: the mod wheel drives vibrato out of the box,
      -- MOD LFO1 PITCH DEPTH 0AH (p.239).
      if row.id == 'mod_lfo1_pitch' then row.default = 10 end
      M.PARAMS[#M.PARAMS + 1] = row
    end
  end
end

M.CC, M.RPN, M.DT1 = CC, RPN, DT1

-- id -> row, so the encoder, the pending snapshot and the session restore can
-- all name a control by its stable key rather than its panel position.
M.BY_ID = {}
local names = {}
for _, p in ipairs(M.PARAMS) do
  assert(not M.BY_ID[p.id], 'duplicate part param id: ' .. p.id)
  M.BY_ID[p.id] = p
  -- Names must be unique too: Insert's take labels and their replacement
  -- match are keyed by name, so two "Pitch Control" rows would delete each
  -- other's labels.
  assert(not names[p.name], 'duplicate part param name: ' .. p.name)
  names[p.name] = true
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
  if p.display == 'enum' then
    assert(type(p.choices) == 'table', p.id .. ': enum row without choices')
    assert(#p.choices == p.max - p.min + 1,
           p.id .. ': enum row needs one choice per value in its range')
  end
  local group_ok = false
  for _, g in ipairs(M.GROUPS) do if g == p.group then group_ok = true break end end
  assert(group_ok, p.id .. ': unknown group ' .. tostring(p.group))
end

-- Whether a control can be written as SysEx at all. Portamento and Portamento
-- Time cannot: the manual documents no musical-state DT1 field for either, so
-- `Use SysEx? on` leaves them on CC rather than inventing an address.
function M.has_sysex(p) return p.dt1 ~= nil end

-- A row's power-on value on one Part. Only Rx Channel differs by Part.
function M.default_for(p, part)
  if p.part_default then return part end
  return p.default
end

-- Clamp a canonical value into a row's range, or return nil when it is not a
-- number at all. Session restore drops what this rejects and keeps the
-- default, per the design's invalid-saved-value rule.
function M.validate(p, v)
  if type(v) ~= 'number' or v ~= v then return nil end
  if v < p.min or v > p.max then return nil end
  return v
end

return M
