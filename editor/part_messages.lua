-- Canonical Part values to wire bytes, for the PAGER Part Editor.
--
-- The only place a musical value becomes MIDI. Everything upstream -- the
-- panel, the pending snapshot, the session state -- speaks the canonical
-- vocabulary part_params.lua defines: Cutoff is -64..+63, Pan is L63..R63,
-- Tuning Offset is Hertz. Every 0x40 offset, every nibblization and the whole
-- RPN dance live here and nowhere else, so a stored value can never be
-- mistaken for a byte that happens to look like it.
--
-- One entry point, `encode`, returns an ordered list of typed events. The
-- same list feeds hardware preview and take insertion, which is what keeps
-- the two from drifting: there is no second walk to fall out of step with.
--
-- Event shapes:
--
--   { kind = 'cc',    channel = 0..15, cc = 0..127, value = 0..127 }
--   { kind = 'sysex', payload = '<bytes without F0/F7>', addr = { a, b, c } }
--
-- `channel` is zero-based, as the MIDI status nibble and REAPER's
-- MIDI_InsertCC both want it. `addr` travels with a SysEx event so phase 4
-- can match a previous write by its complete Part address rather than by
-- finding some SysEx on the tick.
--
-- This module makes no REAPER calls and holds no state.

local GS = require 'gs_sysex'
local P = require 'part_params'

local M = {}

-- RPN controller numbers, and the Null that closes a run. Leaving the RPN
-- selected would make the next stray CC6 anywhere in the take edit this
-- parameter instead (manual p.228).
-- Bank Select. MSB is CC0 and LSB is CC32, per the manual's control-change
-- table (p.226); the SC-8850 selects its own tone map with LSB 4.
local CC_BANK_MSB, CC_BANK_LSB = 0, 32

local CC_DATA_MSB, CC_DATA_LSB = 6, 38
local CC_RPN_LSB, CC_RPN_MSB = 100, 101
local RPN_NULL = 127

-- helpers ---------------------------------------------------------------------

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function round(v)
  return math.floor(v + 0.5)
end

-- A canonical value, clamped to its row and rounded unless the row is
-- continuous. Tuning Offset is the only row with a fractional step, and its
-- rounding happens inside its own encoder where the tenths matter.
local function canonical(p, value)
  assert(type(value) == 'number' and value == value,
         p.id .. ': value must be a number')
  return clamp(value, p.min, p.max)
end

local function cc_event(channel, cc, value)
  return { kind = 'cc', channel = channel, cc = cc, value = value & 0x7F }
end

-- A DT1 write to one Part address. `data` is one or more value bytes; the
-- address is the first of however many consecutive bytes they occupy, which
-- is how the two-byte Tuning Offset and Fine Tune fields are written.
local function dt1_event(addr, data)
  local bytes = { addr[1], addr[2], addr[3] }
  for _, b in ipairs(data) do bytes[#bytes + 1] = b & 0x7F end
  return { kind = 'sysex', payload = GS.dt1(bytes), addr = addr }
end

-- The DT1 address of one row on one Part, following the row's own block.
local function addr_of(p, part)
  local block = p.dt1_block
  if block == 'bend' then return GS.part_bend_addr(part, p.dt1) end
  if block == 'switch' then return GS.part_addr(part, p.dt1) end
  return GS.part_param_addr(part, p.dt1)
end

-- value conversions -------------------------------------------------------------

-- The relative tone modifiers -- cutoff, resonance, the envelope times, the
-- vibrato rows -- are stored as offsets and sent centred on 0x40. Identical
-- for CC and DT1, which is why they share one converter.
local function relative_byte(v)
  return round(v) + 0x40
end

-- Pan is the one row whose two encodings genuinely differ at an endpoint.
--
-- The canonical range L63..C..R63 is symmetric: 127 positions. The DT1 field
-- is the same size, because it reserves 00H for Random and runs 01H..40H..7FH
-- for left..centre..right (manual p.238), so v + 64 lands exactly and Random
-- is simply never produced.
--
-- CC10 has 128 values for that same musical span (manual p.226): hard left is
-- 0, centre is 64, hard right is 127, which leaves the left half one step
-- longer than the right. Centre and everything rightwards is v + 64; the
-- canonical left endpoint is hard left, which is 0 rather than the 1 that
-- formula would give. That single step is the whole difference between the
-- two modes, and it is why L63 is worth its own test.
local function pan_cc_byte(v)
  if v <= -63 then return 0 end
  return round(v) + 64
end

local function pan_dt1_byte(v) return round(v) + 64 end

-- Pitch Key and the Bend Range SysEx form both centre on 0x40: -24..+24
-- semitones become 28H..58H, and 0..24 semitones become 40H..58H.
local function semitone_byte(v)
  return round(v) + 0x40
end

-- Tuning Offset stores tenths of a Hertz, offset by 128 and split into two
-- nibbles (manual p.244 applied to the field on p.238). The endpoints are
-- -12.0 = 00 08H, 0.0 = 08 00H, and +12.0 = 0F 08H.
local function tuning_offset_nibbles(hz)
  local raw = clamp(round(hz * 10) + 128, 0, 0xFF)
  return { (raw >> 4) & 0x0F, raw & 0x0F }
end

-- Fine Tune is a 14-bit value centred on 8192, spanning roughly -100..+100
-- cents across 00 00H..40 00H..7F 7FH. The same pair of bytes is the RPN's
-- Data Entry MSB/LSB and the DT1 field's two bytes.
local function fine_tune_pair(cents)
  local raw = clamp(round(8192 + cents * 81.92), 0, 16383)
  return (raw >> 7) & 0x7F, raw & 0x7F
end

-- An RPN run, in the order the manual documents: select with CC101/CC100,
-- write Data Entry, then close with RPN Null. `lsb` is nil for a 7-bit RPN --
-- Bend Range ignores CC38 -- and present for Fine Tune's 14-bit write.
local function rpn_run(channel, rpn, msb, lsb)
  local out = {
    cc_event(channel, CC_RPN_MSB, (rpn >> 7) & 0x7F),
    cc_event(channel, CC_RPN_LSB, rpn & 0x7F),
    cc_event(channel, CC_DATA_MSB, msb),
  }
  if lsb then out[#out + 1] = cc_event(channel, CC_DATA_LSB, lsb) end
  out[#out + 1] = cc_event(channel, CC_RPN_MSB, RPN_NULL)
  out[#out + 1] = cc_event(channel, CC_RPN_LSB, RPN_NULL)
  return out
end

-- per-row encoders ---------------------------------------------------------------

-- Each row's native (Use SysEx? off) and SysEx (on) forms, keyed by id. A row
-- absent from NATIVE or SYSEX uses the generic single-byte form below, which
-- covers the plain 0..127 rows and the relative modifiers.
--
-- Both halves take (p, part, channel, value) and return an event list, so the
-- caller never has to know which shape a row uses.

local function generic_native(p, part, channel, value)
  if p.native == P.DT1 then
    -- The three rows with no CC or RPN at all fall back to their DT1 form
    -- even with Use SysEx? off; there is nothing else to send.
    return M.sysex_events(p, part, channel, value)
  end
  return { cc_event(channel, p.cc, value) }
end

local NATIVE = {
  pan = function(p, part, channel, value)
    return { cc_event(channel, p.cc, pan_cc_byte(value)) }
  end,
  porta = function(p, part, channel, value)
    -- Off is 0 and On is 127. The hardware reads 0..63 as Off and 64..127 as
    -- On, so the endpoints are used rather than the threshold.
    return { cc_event(channel, p.cc, value >= 1 and 127 or 0) }
  end,
  fine_tune = function(p, part, channel, value)
    local msb, lsb = fine_tune_pair(value)
    return rpn_run(channel, p.rpn, msb, lsb)
  end,
  bend_range = function(p, part, channel, value)
    return rpn_run(channel, p.rpn, round(value))
  end,
  -- Mono is CC126 and Poly is CC127 00 (manual p.229). CC126's value is the
  -- mono channel count, which the SC-8850 ignores -- it sets Mode 4 (M = 1)
  -- whatever arrives -- so 1 is sent, matching the DT1 table's own note.
  mono_poly = function(p, part, channel, value)
    if value < 1 then return { cc_event(channel, p.cc_alt, 1) } end
    return { cc_event(channel, p.cc, 0) }
  end,
}

-- The relative modifiers and Pitch Key differ from the plain rows only in
-- their conversion, so they share one native encoder through this table.
local NATIVE_CONV = {
  cutoff = relative_byte, resonance = relative_byte,
  attack = relative_byte, decay = relative_byte, release = relative_byte,
  vib_rate = relative_byte, vib_depth = relative_byte, vib_delay = relative_byte,
}
for id, conv in pairs(NATIVE_CONV) do
  NATIVE[id] = function(p, part, channel, value)
    return { cc_event(channel, p.cc, conv(value)) }
  end
end

local SYSEX = {
  pan = function(p, part, channel, value)
    return { dt1_event(addr_of(p, part), { pan_dt1_byte(value) }) }
  end,
  pitch_key = function(p, part, channel, value)
    return { dt1_event(addr_of(p, part), { semitone_byte(value) }) }
  end,
  bend_range = function(p, part, channel, value)
    return { dt1_event(addr_of(p, part), { semitone_byte(value) }) }
  end,
  tuning_offset = function(p, part, channel, value)
    return { dt1_event(addr_of(p, part), tuning_offset_nibbles(value)) }
  end,
  fine_tune = function(p, part, channel, value)
    local msb, lsb = fine_tune_pair(value)
    return { dt1_event(addr_of(p, part), { msb, lsb }) }
  end,
  eq = function(p, part, channel, value)
    return { dt1_event(addr_of(p, part), { value >= 1 and 1 or 0 }) }
  end,
}

for id, conv in pairs(NATIVE_CONV) do
  SYSEX[id] = function(p, part, channel, value)
    return { dt1_event(addr_of(p, part), { conv(value) }) }
  end
end

-- The SysEx form of one row. Rows with no DT1 address -- Portamento and
-- Portamento Time -- have none, and stay on CC in both modes.
function M.sysex_events(p, part, channel, value)
  if not P.has_sysex(p) then return nil end
  local build = SYSEX[p.id]
  if build then return build(p, part, channel, value) end
  -- dt1_offset centres a signed field on 40H, or shifts Rx Channel's 1-based
  -- channels to the wire's 0-based ones.
  return { dt1_event(addr_of(p, part), { round(value) + (p.dt1_offset or 0) }) }
end

-- entry point ---------------------------------------------------------------------

-- Encode one control's settled canonical value as an ordered event list.
--
--   id       a part_params row id
--   value    the canonical value, clamped to that row's range
--   part     1..16, the Part within the routed group; also the MIDI channel
--   use_sysex  the channel's Use SysEx? setting
--
-- `part` doubles as the channel because the design binds them: the piano-roll
-- channel selects the Part, and the track's hardware output selects the group.
-- The returned list is in send order and must not be reordered -- an RPN run
-- whose Null arrives before its Data Entry writes nothing.
function M.encode(id, value, part, use_sysex)
  local p = P.BY_ID[id]
  assert(p, 'unknown part parameter: ' .. tostring(id))
  assert(part and part >= 1 and part <= 16, 'part must be 1..16')

  local v = canonical(p, value)
  local channel = part - 1

  if use_sysex then
    local events = M.sysex_events(p, part, channel, v)
    -- Portamento has no SysEx form; it falls through to its CC encoding
    -- rather than silently sending nothing.
    if events then return events end
  end

  local build = NATIVE[p.id] or generic_native
  return build(p, part, channel, v)
end

-- A voice selection: Bank Select MSB, Bank Select LSB, then Program Change.
--
-- Not a PARAMS row, because a voice is not a parameter with a range -- it is
-- an address into the tone map, and its three messages must arrive in this
-- order. Bank Select is latched by the hardware and only takes effect when
-- the Program Change arrives, so a PC sent without its bank bytes selects
-- from whichever bank was last set, which is how a voice change appears to
-- work and picks the wrong instrument.
--
-- Returned as a run, so the queue keeps the three together and never
-- reorders or coalesces them.
function M.voice_events(part, msb, lsb, pc)
  assert(part and part >= 1 and part <= 16, 'part must be 1..16')
  for _, n in ipairs({ msb, lsb, pc }) do
    assert(type(n) == 'number' and n >= 0 and n <= 127,
           'voice bytes must be 0..127')
  end
  local channel = part - 1
  return {
    cc_event(channel, CC_BANK_MSB, msb),
    cc_event(channel, CC_BANK_LSB, lsb),
    { kind = 'pc', channel = channel, program = pc & 0x7F },
  }
end

-- Whether an event list is an ordered run rather than a single message. The
-- hardware queue keeps a run together as a batch, and phase 4 matches one for
-- replacement across its whole PPQ span.
function M.is_run(events) return #events > 1 end

M.CC_BANK_MSB, M.CC_BANK_LSB = CC_BANK_MSB, CC_BANK_LSB
M.CC_DATA_MSB, M.CC_DATA_LSB = CC_DATA_MSB, CC_DATA_LSB
M.CC_RPN_LSB, M.CC_RPN_MSB, M.RPN_NULL = CC_RPN_LSB, CC_RPN_MSB, RPN_NULL

-- Exposed for the tests, which pin the conversions independently of the rows
-- that use them.
M._conv = {
  relative_byte = relative_byte,
  pan_cc_byte = pan_cc_byte, pan_dt1_byte = pan_dt1_byte,
  semitone_byte = semitone_byte,
  tuning_offset_nibbles = tuning_offset_nibbles,
  fine_tune_pair = fine_tune_pair,
}

return M
