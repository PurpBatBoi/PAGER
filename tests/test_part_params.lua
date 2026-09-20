-- Phase 1: the Part Editor's protocol foundation.
--
-- Two things are pinned here, both of them data rather than behaviour:
--
--   the Part address helpers added to gs_sysex.lua -- 40 1x, 40 2x and the
--   address read-back used later for targeted replacement -- at the block
--   edges that the PART_BLOCK map makes non-obvious (Parts 10 and 16);
--
--   every row of part_params.lua: its canonical range, its default, its
--   group, and which wire encoding `Use SysEx? off` selects for it.
--
-- The table is transcribed from the SC-8850 manual through
-- docs/research-part-editor-midi-mapping.md, so a typo in it is invisible
-- until hardware does the wrong thing. Nothing here encodes a value -- the
-- encoders arrive in phase 2 and are tested separately.
--   lua tests/test_part_params.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local GS = require 'gs_sysex'
local P = require 'part_params'
local check = H.check

-- part addresses -------------------------------------------------------------

-- The block nibble is not the Part number. Parts 1-9 map to 1-9, Part 10 maps
-- to 0, and Parts 11-16 map to A-F, so the two ends of the map are where an
-- off-by-one would hide.
local function addr_str(a)
  return ('%02X %02X %02X'):format(a[1], a[2], a[3])
end

local PARAM_CASES = {
  { part = 1,  lo = 0x19, want = '40 11 19' }, -- Part 1 Level
  { part = 9,  lo = 0x19, want = '40 19 19' },
  { part = 10, lo = 0x19, want = '40 10 19' }, -- block 0, not 10
  { part = 11, lo = 0x19, want = '40 1A 19' }, -- block A, not B
  { part = 16, lo = 0x19, want = '40 1F 19' },
  { part = 1,  lo = 0x1C, want = '40 11 1C' }, -- Part 1 Pan
  { part = 16, lo = 0x2A, want = '40 1F 2A' }, -- Part 16 Fine Tune
}
for _, c in ipairs(PARAM_CASES) do
  local got = addr_str(GS.part_param_addr(c.part, c.lo))
  check(got == c.want,
        ('part_param_addr(%d, 0x%02X) = %s, expected %s')
          :format(c.part, c.lo, got, c.want))
end

local BEND_CASES = {
  { part = 1,  want = '40 21 10' },
  { part = 10, want = '40 20 10' },
  { part = 16, want = '40 2F 10' },
}
for _, c in ipairs(BEND_CASES) do
  local got = addr_str(GS.part_bend_addr(c.part, 0x10))
  check(got == c.want,
        ('part_bend_addr(%d, 0x10) = %s, expected %s')
          :format(c.part, got, c.want))
end

-- The three families must stay distinct on the same Part. 40 1x, 40 2x and
-- 40 4x differ only in the high nibble of the middle byte, which is exactly
-- the kind of thing a copy-paste collapses.
for part = 1, 16 do
  local p = GS.part_param_addr(part, 0x19)[2]
  local b = GS.part_bend_addr(part, 0x10)[2]
  local s = GS.part_eq_addr(part)[2]
  check(p ~= b and b ~= s and p ~= s,
        'part ' .. part .. ': the three address blocks must not collide')
  check(p >= 0x10 and p <= 0x1F, 'part ' .. part .. ': param block left 40 1x')
  check(b >= 0x20 and b <= 0x2F, 'part ' .. part .. ': bend block left 40 2x')
  check(s >= 0x40 and s <= 0x4F, 'part ' .. part .. ': switch block left 40 4x')
end

check(not pcall(GS.part_param_addr, 17, 0x19), 'part 17 must be rejected')
check(not pcall(GS.part_param_addr, 0, 0x19), 'part 0 must be rejected')

-- address read-back ----------------------------------------------------------

-- dt1_addr_of answers "which address is this payload writing", which is what
-- targeted replacement needs at a tick where it does not know which parameter
-- wrote first. It must read back exactly what dt1() put in.
for _, part in ipairs({ 1, 10, 16 }) do
  local a = GS.part_param_addr(part, 0x19)
  local payload = GS.dt1({ a[1], a[2], a[3], 64 })
  local back = GS.dt1_addr_of(payload)
  check(back and addr_str(back) == addr_str(a),
        'dt1_addr_of must round-trip part ' .. part .. ' level')
end

-- Anything that is not a GS DT1 write must not be claimed as one. A universal
-- SysEx master-volume message has neither the Roland ID nor the DT1 command,
-- and a truncated payload has no address to read at all.
check(GS.dt1_addr_of(GS.master_volume(64)) == nil,
      'a universal SysEx payload is not a DT1 address')
check(GS.dt1_addr_of('') == nil, 'an empty payload has no address')
check(GS.dt1_addr_of(nil) == nil, 'nil has no address')
check(GS.dt1_addr_of(string.char(0x41, 0x10, 0x42)) == nil,
      'a truncated payload has no address')

-- part parameter table -------------------------------------------------------

-- The full transcription, restated independently of part_params.lua so the
-- two have to agree. Columns: id, group, min, max, default, native encoding,
-- and the wire number that encoding uses -- controller, RPN, or DT1 low byte.
local EXPECT = {
  { 'level',         'Sends and Mix',            0,   127,  100, 'cc',   7,  0x19 },
  { 'pan',           'Sends and Mix',          -63,    63,    0, 'cc',  10,  0x1C },
  { 'reverb',        'Sends and Mix',            0,   127,   40, 'cc',  91,  0x22 },
  { 'chorus',        'Sends and Mix',            0,   127,    0, 'cc',  93,  0x21 },
  { 'delay',         'Sends and Mix',            0,   127,    0, 'cc',  94,  0x2C },
  { 'cutoff',        'Filter',                 -64,    63,    0, 'cc',  74,  0x32 },
  { 'resonance',     'Filter',                 -64,    63,    0, 'cc',  71,  0x33 },
  { 'attack',        'Envelope',               -64,    63,    0, 'cc',  73,  0x34 },
  { 'decay',         'Envelope',               -64,    63,    0, 'cc',  75,  0x35 },
  { 'release',       'Envelope',               -64,    63,    0, 'cc',  72,  0x36 },
  { 'tuning_offset', 'Tuning',                 -12,    12,    0, 'dt1', nil, 0x17 },
  { 'fine_tune',     'Tuning',                -100, 99.99,    0, 'rpn',   1, 0x2A },
  { 'vib_rate',      'Vibrato',                -64,    63,    0, 'cc',  76,  0x30 },
  { 'vib_depth',     'Vibrato',                -64,    63,    0, 'cc',  77,  0x31 },
  { 'vib_delay',     'Vibrato',                -64,    63,    0, 'cc',  78,  0x37 },
  { 'eq',            'Switches and Performance', 0,     1,    1, 'dt1', nil, 0x20 },
  { 'porta',         'Switches and Performance', 0,     1,    0, 'cc',  65,  nil  },
  { 'porta_time',    'Switches and Performance', 0,   127,    0, 'cc',   5,  nil  },
  { 'pitch_key',     'Switches and Performance', -24,   24,   0, 'dt1', nil, 0x16 },
  { 'bend_range',    'Switches and Performance', 0,     24,   2, 'rpn',   0, 0x10 },
}

check(#P.PARAMS == #EXPECT,
      ('part_params has %d rows, the table pins %d'):format(#P.PARAMS, #EXPECT))

for i, want in ipairs(EXPECT) do
  local id, group, min, max, default, native, number, dt1 = table.unpack(want, 1, 8)
  local p = P.PARAMS[i]
  check(p.id == id, ('row %d is %s, expected %s'):format(i, p.id, id))
  check(p.group == group, id .. ': group is ' .. tostring(p.group))
  check(p.min == min, ('%s: min is %s, expected %s'):format(id, p.min, min))
  check(p.max == max, ('%s: max is %s, expected %s'):format(id, p.max, max))
  check(p.default == default,
        ('%s: default is %s, expected %s'):format(id, p.default, default))
  check(p.native == native,
        ('%s: native is %s, expected %s'):format(id, p.native, native))
  check(p.dt1 == dt1,
        ('%s: dt1 low byte is %s, expected %s')
          :format(id, tostring(p.dt1), tostring(dt1)))
  if native == 'cc' then
    check(p.cc == number, ('%s: cc is %s, expected %s'):format(id, p.cc, number))
  elseif native == 'rpn' then
    check(p.rpn == number, ('%s: rpn is %s, expected %s'):format(id, p.rpn, number))
  end
  check(P.BY_ID[id] == p, id .. ': BY_ID must point at the same row')
end

-- The panel draws groups in this order, and every row must belong to one of
-- them. A row in an unlisted group would simply never be drawn.
local GROUP_ORDER = { 'Sends and Mix', 'Filter', 'Envelope', 'Tuning',
                      'Vibrato', 'Switches and Performance' }
check(#P.GROUPS == #GROUP_ORDER, 'GROUPS must list exactly the six sections')
for i, g in ipairs(GROUP_ORDER) do
  check(P.GROUPS[i] == g, ('group %d is %s, expected %s'):format(i, P.GROUPS[i], g))
end

-- Rows are contiguous within a group: the panel walks PARAMS once per group,
-- so a row filed out of order would appear under the wrong heading.
local seen_group, order = {}, {}
for _, p in ipairs(P.PARAMS) do
  if order[#order] ~= p.group then
    check(not seen_group[p.group], p.group .. ': rows are not contiguous')
    seen_group[p.group] = true
    order[#order + 1] = p.group
  end
end
check(#order == #GROUP_ORDER, 'every group must hold at least one row')

-- the three deliberate deviations ---------------------------------------------

-- These are the rows most likely to be "corrected" into being wrong, so each
-- one states its reason where a reader will hit it.

-- EQ, Tuning Offset and Pitch Key use DT1 even with `Use SysEx?` off. The
-- first two have no CC/RPN/NRPN at all; Pitch Key has RPN 2 over the same
-- range, but the manual never calls RPN 2 the stored PITCH KEY SHIFT field.
for _, id in ipairs({ 'eq', 'tuning_offset', 'pitch_key' }) do
  check(P.BY_ID[id].native == P.DT1,
        id .. ' must fall back to DT1 with Use SysEx? off')
end

-- Portamento is CC in BOTH modes: the DT1 Rx. PORTAMENTO field enables
-- receipt of portamento messages and is not the audible on/off state.
for _, id in ipairs({ 'porta', 'porta_time' }) do
  check(P.BY_ID[id].native == P.CC, id .. ' must stay native CC')
  check(not P.has_sysex(P.BY_ID[id]),
        id .. ' must have no SysEx form, so Use SysEx? on cannot change it')
end

-- Every other row does have a SysEx form, or `Use SysEx? on` would silently
-- do nothing for it.
for _, p in ipairs(P.PARAMS) do
  if p.id ~= 'porta' and p.id ~= 'porta_time' then
    check(P.has_sysex(p), p.id .. ' must have a DT1 address')
  end
end

-- Address family per row. Only Bend Range lives on 40 2x and only EQ on
-- 40 4x; everything else is a Patch Part parameter on 40 1x.
check(P.BY_ID.bend_range.dt1_block == 'bend', 'bend range is a 40 2x address')
check(P.BY_ID.eq.dt1_block == 'switch', 'EQ is a 40 4x address')
for _, p in ipairs(P.PARAMS) do
  if p.id ~= 'bend_range' and p.id ~= 'eq' then
    check(p.dt1_block == nil, p.id .. ' must use the default 40 1x block')
  end
end

-- The two multi-byte DT1 values, and only those two.
check(P.BY_ID.tuning_offset.dt1_len == 2, 'tuning offset spans 17..18')
check(P.BY_ID.fine_tune.dt1_len == 2, 'fine tune spans 2A..2B')
for _, p in ipairs(P.PARAMS) do
  if p.id ~= 'tuning_offset' and p.id ~= 'fine_tune' then
    check(p.dt1_len == nil, p.id .. ' must be a single-byte DT1 value')
  end
end

-- Fine Tune is the only 14-bit RPN: Bend Range writes CC6 and ignores CC38.
check(P.BY_ID.fine_tune.rpn_fine == true, 'fine tune uses CC6 and CC38')
check(P.BY_ID.bend_range.rpn_fine == nil, 'bend range uses CC6 alone')

-- validation -----------------------------------------------------------------

-- What a session restore keeps and what it drops. Anything outside a row's
-- own documented range is dropped rather than clamped: a clamped value looks
-- deliberate on screen and the user cannot see which field came back wrong.
local cutoff = P.BY_ID.cutoff
check(P.validate(cutoff, 0) == 0, 'the default must validate')
check(P.validate(cutoff, -64) == -64, 'the low endpoint must validate')
check(P.validate(cutoff, 63) == 63, 'the high endpoint must validate')
check(P.validate(cutoff, -65) == nil, 'below the range must be dropped')
check(P.validate(cutoff, 64) == nil, 'above the range must be dropped')
check(P.validate(cutoff, 'x') == nil, 'a non-number must be dropped')
check(P.validate(cutoff, nil) == nil, 'nil must be dropped')
check(P.validate(cutoff, 0 / 0) == nil, 'NaN must be dropped')

-- Every row's own default and endpoints must survive its own validator.
for _, p in ipairs(P.PARAMS) do
  check(P.validate(p, p.default) == p.default, p.id .. ': default must validate')
  check(P.validate(p, p.min) == p.min, p.id .. ': min must validate')
  check(P.validate(p, p.max) == p.max, p.id .. ': max must validate')
end

H.pass('part addresses, part parameter table and validation')
