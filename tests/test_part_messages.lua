-- Phase 2: canonical Part values to wire bytes.
--
-- Every control, in both `Use SysEx?` modes, at both range endpoints and at
-- its centre, asserted as exact bytes. This is the layer where a wrong offset
-- or a transposed nibble is completely silent -- the panel still reads right,
-- the take still contains an event, and only the hardware disagrees -- so the
-- expectations here are written out longhand from the manual rather than
-- derived from the module they check.
--
-- Also pinned: the RPN run order, which must survive any later refactor. An
-- RPN whose Null arrives before its Data Entry writes nothing at all, and the
-- take would still look plausible.
--   lua tests/test_part_messages.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local GS = require 'gs_sysex'
local P = require 'part_params'
local PM = require 'part_messages'
local check = H.check

-- readable failures ----------------------------------------------------------

local function hex(s)
  local out = {}
  for i = 1, #s do out[i] = ('%02X'):format(s:byte(i)) end
  return table.concat(out, ' ')
end

-- One event as a short string, so a mismatch prints what actually came out
-- rather than a table address.
local function show(e)
  if e.kind == 'cc' then
    return ('cc ch%d #%d=%d'):format(e.channel, e.cc, e.value)
  end
  return 'sysex ' .. hex(e.payload)
end

local function show_all(events)
  local out = {}
  for i, e in ipairs(events) do out[i] = show(e) end
  return table.concat(out, ' | ')
end

-- Assert an encoding by its rendered form, which keeps the expectations below
-- readable as MIDI rather than as nested tables.
local function enc(id, value, part, use_sysex)
  return show_all(PM.encode(id, value, part, use_sysex))
end

local function expect(id, value, part, use_sysex, want, what)
  local got = enc(id, value, part, use_sysex)
  check(got == want, ('%s (%s = %s, part %d): got %s, expected %s')
    :format(what or id, id, tostring(value), part, got, want))
end

-- The DT1 payload a Part address and data bytes must produce, built through
-- gs_sysex so the checksum is the real one. Restating the checksum by hand
-- here would only test the arithmetic twice.
local function dt1(addr, ...)
  local bytes = { addr[1], addr[2], addr[3] }
  for _, b in ipairs({ ... }) do bytes[#bytes + 1] = b end
  return 'sysex ' .. hex(GS.dt1(bytes))
end

local function param(part, lo) return GS.part_param_addr(part, lo) end

-- channel binding --------------------------------------------------------------

-- The Part number is the MIDI channel, one-based on screen and zero-based on
-- the wire. Part 1 is channel 0 and Part 16 is channel 15; getting this wrong
-- would send every edit to the neighbouring Part.
expect('level', 100, 1, false, 'cc ch0 #7=100', 'part 1 is channel 0')
expect('level', 100, 16, false, 'cc ch15 #7=100', 'part 16 is channel 15')
check(not pcall(PM.encode, 'level', 100, 0, false), 'part 0 must be rejected')
check(not pcall(PM.encode, 'level', 100, 17, false), 'part 17 must be rejected')
check(not pcall(PM.encode, 'nope', 0, 1, false), 'an unknown id must be rejected')

-- plain 0..127 rows --------------------------------------------------------------

-- Level, the sends and Portamento Time are the simple case: the canonical
-- value IS the byte, in both modes.
local PLAIN = {
  { 'level',  7, 0x19 },
  { 'reverb', 91, 0x22 },
  { 'chorus', 93, 0x21 },
  { 'delay',  94, 0x2C },
}
for _, row in ipairs(PLAIN) do
  local id, cc, lo = row[1], row[2], row[3]
  for _, v in ipairs({ 0, 64, 127 }) do
    expect(id, v, 1, false, ('cc ch0 #%d=%d'):format(cc, v))
    expect(id, v, 1, true, dt1(param(1, lo), v))
  end
end

-- Portamento Time has no SysEx form, so `Use SysEx? on` must still send CC5
-- rather than nothing.
expect('porta_time', 64, 1, false, 'cc ch0 #5=64')
expect('porta_time', 64, 1, true, 'cc ch0 #5=64', 'porta time stays CC with SysEx on')

-- relative tone modifiers --------------------------------------------------------

-- Stored as offsets, sent centred on 40H. The same conversion serves CC and
-- DT1, so both modes must agree byte for byte at every endpoint.
local RELATIVE = {
  { 'cutoff',    74, 0x32 },
  { 'resonance', 71, 0x33 },
  { 'attack',    73, 0x34 },
  { 'decay',     75, 0x35 },
  { 'release',   72, 0x36 },
  { 'vib_rate',  76, 0x30 },
  { 'vib_depth', 77, 0x31 },
  { 'vib_delay', 78, 0x37 },
}
for _, row in ipairs(RELATIVE) do
  local id, cc, lo = row[1], row[2], row[3]
  local cases = { { -64, 0 }, { 0, 64 }, { 63, 127 }, { 20, 84 }, { -20, 44 } }
  for _, c in ipairs(cases) do
    local v, byte = c[1], c[2]
    expect(id, v, 1, false, ('cc ch0 #%d=%d'):format(cc, byte))
    expect(id, v, 1, true, dt1(param(1, lo), byte))
  end
end

-- pan: the one row whose endpoints differ between modes ---------------------------

-- CC10 puts hard left at 0; the DT1 field reserves 0 for Random and starts
-- ordinary left at 1. Everything from L62 rightwards is identical, which is
-- what makes the left endpoint easy to miss.
expect('pan', -63, 1, false, 'cc ch0 #10=0', 'CC hard left is 0')
expect('pan', -63, 1, true, dt1(param(1, 0x1C), 1), 'DT1 hard left is 1, not Random')
expect('pan', -62, 1, false, 'cc ch0 #10=2')
expect('pan', -62, 1, true, dt1(param(1, 0x1C), 2), 'L62 is the same in both modes')
expect('pan', 0, 1, false, 'cc ch0 #10=64')
expect('pan', 0, 1, true, dt1(param(1, 0x1C), 64))
expect('pan', 63, 1, false, 'cc ch0 #10=127')
expect('pan', 63, 1, true, dt1(param(1, 0x1C), 127))

-- Random is DT1 value 0 and must be unreachable from the panel: no canonical
-- value may encode to it.
for v = -63, 63 do
  local e = PM.encode('pan', v, 1, true)[1]
  check(e.payload:byte(8) ~= 0, 'pan ' .. v .. ' must not encode as Random')
end

-- switches ------------------------------------------------------------------------

-- Portamento is CC65 in BOTH modes: the DT1 Rx. PORTAMENTO field enables
-- receipt of portamento messages and is not the audible on/off state.
expect('porta', 0, 1, false, 'cc ch0 #65=0')
expect('porta', 1, 1, false, 'cc ch0 #65=127')
expect('porta', 0, 1, true, 'cc ch0 #65=0', 'portamento stays CC with SysEx on')
expect('porta', 1, 1, true, 'cc ch0 #65=127', 'portamento stays CC with SysEx on')

-- Mono/Poly is two controllers (manual p.229): Mono is CC126 (value ignored
-- by the unit, 1 sent) and Poly is CC127 00. SysEx is 40 1x 13, 00/01
-- (p.238). Part 10 checks the 40 1x block follows the Part.
expect('mono_poly', 0, 1, false, 'cc ch0 #126=1')
expect('mono_poly', 1, 1, false, 'cc ch0 #127=0')
expect('mono_poly', 0, 10, false, 'cc ch9 #126=1')
expect('mono_poly', 0, 1, true, dt1(param(1, 0x13), 0))
expect('mono_poly', 1, 1, true, dt1(param(1, 0x13), 1))
expect('mono_poly', 1, 10, true, dt1(param(10, 0x13), 1))

-- Keyboard rows are DT1 in both modes (no CC exists). Rx Channel is 1-based
-- on screen and 0-based on the wire, with 17 = Off = 10H (p.237).
expect('rx_channel', 1, 1, false, dt1(param(1, 0x02), 0x00))
expect('rx_channel', 16, 1, true, dt1(param(1, 0x02), 0x0F))
expect('rx_channel', 17, 3, true, dt1(param(3, 0x02), 0x10), 'Rx Channel Off')
expect('assign_mode', 2, 1, false, dt1(param(1, 0x14), 2))
expect('vel_depth', 90, 1, true, dt1(param(1, 0x1A), 90))
expect('vel_offset', 30, 1, true, dt1(param(1, 0x1B), 30))
expect('key_low', 36, 1, true, dt1(param(1, 0x1D), 36))
expect('key_high', 96, 1, false, dt1(param(1, 0x1E), 96))

-- Scale Tuning: C at 40 1x 40, B at 4B, -64..+63 centred on 40H (p.238).
expect('scale_c', -64, 1, true, dt1(param(1, 0x40), 0x00))
expect('scale_c', 0, 1, false, dt1(param(1, 0x40), 0x40))
expect('scale_b', 63, 1, true, dt1(param(1, 0x4B), 0x7F))

-- The 40 2x controller block (pp.239-240). Pitch Control is 28H..58H for
-- -24..+24; the other centred fields sit on 40H; depths are the raw byte.
local function bend(part, lo) return GS.part_bend_addr(part, lo) end
expect('mod_pitch', -24, 1, true, dt1(bend(1, 0x00), 0x28))
expect('mod_pitch', 24, 1, false, dt1(bend(1, 0x00), 0x58))
expect('mod_cutoff', 10, 1, true, dt1(bend(1, 0x01), 0x4A))
expect('mod_lfo1_pitch', 10, 1, true, dt1(bend(1, 0x04), 0x0A))
expect('bend_cutoff', -64, 1, true, dt1(bend(1, 0x11), 0x00))
expect('caf_lfo2_tva', 127, 1, true, dt1(bend(1, 0x2A), 0x7F))
expect('paf_amp', 0, 10, true, dt1(bend(10, 0x32), 0x40), 'Part 10 uses block 0')
expect('cc1_pitch', 12, 1, true, dt1(bend(1, 0x40), 0x4C))
expect('cc2_lfo2_tva', 100, 1, false, dt1(bend(1, 0x5A), 100))
expect('cc1_number', 16, 1, true, dt1(param(1, 0x1F), 0x10))

-- Output Assign: the manual's own worked example (p.61), byte for byte --
-- Part 1 to OUTPUT-2 is F0 41 10 42 12 40 41 21 01 5D F7.
expect('output', 1, 1, true, 'sysex ' .. hex(string.char(0x41, 0x10, 0x42, 0x12,
                                                         0x40, 0x41, 0x21, 0x01, 0x5D)),
       'Output Assign matches the manual example')
expect('output', 3, 10, false, dt1(GS.part_addr(10, 0x21), 3), 'Output 2R, SysEx off')

-- Receive switches are DT1 in both modes: 40 1x 03 .. 12, 23, 24.
expect('rx_bend', 0, 1, false, dt1(param(1, 0x03), 0))
expect('rx_nrpn', 1, 1, true, dt1(param(1, 0x0A), 1))
expect('rx_bank_lsb', 0, 16, true, dt1(param(16, 0x24), 0))
expect('cc2_number', 95, 1, true, dt1(param(1, 0x20), 0x5F))

-- EQ has no CC at all, so both modes send the 40 4x 20 switch. These bytes
-- are the hardware capture gs_sysex.lua already asserts against.
local EQ_ON = 'sysex ' .. hex(string.char(0x41, 0x10, 0x42, 0x12,
                                          0x40, 0x41, 0x20, 0x01, 0x5E))
local EQ_OFF = 'sysex ' .. hex(string.char(0x41, 0x10, 0x42, 0x12,
                                           0x40, 0x41, 0x20, 0x00, 0x5F))
expect('eq', 1, 1, true, EQ_ON, 'EQ on matches the hardware capture')
expect('eq', 0, 1, true, EQ_OFF, 'EQ off matches the hardware capture')
expect('eq', 1, 1, false, EQ_ON, 'EQ falls back to DT1 with SysEx off')
expect('eq', 0, 1, false, EQ_OFF, 'EQ falls back to DT1 with SysEx off')

-- pitch key: DT1 in both modes ------------------------------------------------------

-- RPN 2 covers the same coarse range, but the manual never identifies it as
-- the stored PITCH KEY SHIFT field, so this editor does not claim they are
-- the same parameter. -24..+24 becomes 28H..58H.
for _, c in ipairs({ { -24, 0x28 }, { 0, 0x40 }, { 24, 0x58 }, { 7, 0x47 } }) do
  local want = dt1(param(1, 0x16), c[2])
  expect('pitch_key', c[1], 1, true, want)
  expect('pitch_key', c[1], 1, false, want, 'pitch key falls back to DT1')
end

-- tuning offset: nibblized tenths of a Hertz --------------------------------------

-- raw = round(hz * 10) + 128, split as [raw >> 4, raw & 0x0F]. The manual's
-- endpoints are -12.0 = 00 08H, 0.0 = 08 00H, +12.0 = 0F 08H.
local TUNING = {
  { -12.0, 0x00, 0x08 },
  {   0.0, 0x08, 0x00 },
  {  12.0, 0x0F, 0x08 },
  {  -0.1, 0x07, 0x0F },
  {   0.1, 0x08, 0x01 },
}
for _, c in ipairs(TUNING) do
  local want = dt1(param(1, 0x17), c[2], c[3])
  expect('tuning_offset', c[1], 1, true, want)
  expect('tuning_offset', c[1], 1, false, want, 'tuning offset falls back to DT1')
end

-- Every nibble must stay a nibble. A raw byte written straight into the
-- second slot would exceed 0x0F and the hardware would read a different
-- field entirely.
for tenths = -120, 120 do
  local n = PM._conv.tuning_offset_nibbles(tenths / 10)
  check(n[1] >= 0 and n[1] <= 0x0F and n[2] >= 0 and n[2] <= 0x0F,
        'tuning offset nibbles out of range at ' .. tenths / 10 .. ' Hz')
end

-- fine tune: 14 bits, two encodings -------------------------------------------------

-- Centre is 40 00H. The RPN form writes the same MSB/LSB pair as the DT1
-- form, which is the point of checking them against each other.
local function fine(cents)
  local msb, lsb = PM._conv.fine_tune_pair(cents)
  return msb, lsb
end

local c_msb, c_lsb = fine(0)
check(c_msb == 0x40 and c_lsb == 0x00,
      ('fine tune centre is %02X %02X, expected 40 00'):format(c_msb, c_lsb))
local lo_msb, lo_lsb = fine(-100)
check(lo_msb == 0x00 and lo_lsb == 0x00,
      ('fine tune floor is %02X %02X, expected 00 00'):format(lo_msb, lo_lsb))
local hi_msb, hi_lsb = fine(99.99)
check(hi_msb == 0x7F and hi_lsb == 0x7F,
      ('fine tune ceiling is %02X %02X, expected 7F 7F'):format(hi_msb, hi_lsb))

expect('fine_tune', 0, 1, true, dt1(param(1, 0x2A), 0x40, 0x00))
expect('fine_tune', -100, 1, true, dt1(param(1, 0x2A), 0x00, 0x00))
expect('fine_tune', 99.99, 1, true, dt1(param(1, 0x2A), 0x7F, 0x7F))

-- RPN order ---------------------------------------------------------------------------

-- Select with CC101/CC100, write Data Entry, close with RPN Null. Fine Tune
-- is the only 14-bit write, so it is the only one that sends CC38.
expect('fine_tune', 0, 1, false,
       'cc ch0 #101=0 | cc ch0 #100=1 | cc ch0 #6=64 | cc ch0 #38=0 | ' ..
       'cc ch0 #101=127 | cc ch0 #100=127',
       'fine tune RPN 1, 14-bit')

-- Bend Range is RPN 0 and ignores CC38, so its run is one message shorter.
expect('bend_range', 2, 1, false,
       'cc ch0 #101=0 | cc ch0 #100=0 | cc ch0 #6=2 | ' ..
       'cc ch0 #101=127 | cc ch0 #100=127',
       'bend range RPN 0, 7-bit')
expect('bend_range', 0, 1, false,
       'cc ch0 #101=0 | cc ch0 #100=0 | cc ch0 #6=0 | ' ..
       'cc ch0 #101=127 | cc ch0 #100=127')
expect('bend_range', 24, 1, false,
       'cc ch0 #101=0 | cc ch0 #100=0 | cc ch0 #6=24 | ' ..
       'cc ch0 #101=127 | cc ch0 #100=127')

-- The Null must be last, or the RPN stays selected and the next stray CC6
-- anywhere in the take edits this parameter instead.
for _, id in ipairs({ 'fine_tune', 'bend_range' }) do
  local run = PM.encode(id, 0, 1, false)
  local n = #run
  check(run[n - 1].cc == 101 and run[n - 1].value == 127 and
        run[n].cc == 100 and run[n].value == 127,
        id .. ': an RPN run must end with RPN Null')
  check(run[1].cc == 101 and run[2].cc == 100,
        id .. ': an RPN run must select before it writes')
  check(PM.is_run(run), id .. ': an RPN run is a run, not a single message')
end

-- Bend Range's SysEx form is a single DT1 write on the 40 2x block, centred
-- on 0x40 like Pitch Key: 0..24 becomes 40H..58H, default 2 is 42H.
expect('bend_range', 2, 1, true, dt1(GS.part_bend_addr(1, 0x10), 0x42))
expect('bend_range', 0, 1, true, dt1(GS.part_bend_addr(1, 0x10), 0x40))
expect('bend_range', 24, 1, true, dt1(GS.part_bend_addr(1, 0x10), 0x58))
check(not PM.is_run(PM.encode('bend_range', 2, 1, true)),
      'the SysEx form of bend range is one message, not a run')

-- part blocks ---------------------------------------------------------------------------

-- The block nibble is not the Part number, so every SysEx row must be checked
-- at the two edges the PART_BLOCK map makes non-obvious.
expect('level', 100, 10, true, dt1(param(10, 0x19), 100), 'part 10 uses block 0')
expect('level', 100, 16, true, dt1(param(16, 0x19), 100), 'part 16 uses block F')
expect('bend_range', 2, 10, true, dt1(GS.part_bend_addr(10, 0x10), 0x42))
expect('eq', 1, 16, true, dt1(GS.part_eq_addr(16), 1), 'part 16 EQ uses block F')

-- Part 10's channel is still 9, independently of its block being 0. These two
-- mappings are unrelated and collapsing them would be easy.
expect('level', 100, 10, false, 'cc ch9 #7=100', 'part 10 is channel 9')

-- clamping and defaults ----------------------------------------------------------------

-- Out-of-range values are clamped rather than allowed to produce a byte
-- outside 0..127, which the hardware would read as a status byte.
expect('level', 999, 1, false, 'cc ch0 #7=127', 'above the range clamps')
expect('level', -5, 1, false, 'cc ch0 #7=0', 'below the range clamps')
expect('cutoff', 500, 1, false, 'cc ch0 #74=127')
expect('cutoff', -500, 1, false, 'cc ch0 #74=0')
check(not pcall(PM.encode, 'level', 'x', 1, false), 'a non-number must be rejected')
check(not pcall(PM.encode, 'level', 0 / 0, 1, false), 'NaN must be rejected')

-- every row, every mode ------------------------------------------------------------------

-- The sweep: no row may produce an empty list, a byte outside 0..127, or a
-- malformed DT1 payload, at any point in its own range on any Part.
for _, p in ipairs(P.PARAMS) do
  for _, use_sysex in ipairs({ false, true }) do
    for _, part in ipairs({ 1, 10, 16 }) do
      for _, v in ipairs({ p.min, p.default, p.max }) do
        local events = PM.encode(p.id, v, part, use_sysex)
        check(#events > 0, p.id .. ': encoded to nothing')
        for _, e in ipairs(events) do
          if e.kind == 'cc' then
            check(e.channel == part - 1, p.id .. ': wrong channel')
            check(e.cc >= 0 and e.cc <= 127, p.id .. ': controller out of range')
            check(e.value >= 0 and e.value <= 127, p.id .. ': value out of range')
          else
            check(e.kind == 'sysex', p.id .. ': unknown event kind')
            local addr = GS.dt1_addr_of(e.payload)
            check(addr, p.id .. ': payload is not a readable DT1 write')
            check(e.addr and e.addr[1] == addr[1] and e.addr[2] == addr[2]
                  and e.addr[3] == addr[3],
                  p.id .. ': the event addr must match its own payload')
            for i = 1, #e.payload do
              check(e.payload:byte(i) <= 0x7F,
                    p.id .. ': a payload byte exceeded 7 bits')
            end
          end
        end
      end
    end
  end
end

-- With `Use SysEx? on`, every row that has a DT1 address must actually use
-- it, and the two that do not must stay on CC.
for _, p in ipairs(P.PARAMS) do
  local events = PM.encode(p.id, p.default, 1, true)
  if P.has_sysex(p) then
    check(events[1].kind == 'sysex', p.id .. ': SysEx mode must send DT1')
  else
    check(events[1].kind == 'cc', p.id .. ': this row has no SysEx form')
  end
end

H.pass('part encoders: every control, both modes, endpoints, RPN order and part blocks')

-- Use For Rhythm ---------------------------------------------------------------

-- Which drum map a Part plays: 40 1x 15, values 0/1/2 (manual p.238).
--
-- SysEx-only, so both modes must produce the same DT1 write -- there is no
-- CC form for `Use SysEx? off` to fall back to, and silently sending nothing
-- would look exactly like a Part that refused to change.
do
  local CASES = {
    -- part, value, the 1x block byte the manual gives
    { 1,  0, 0x11 },
    { 1,  2, 0x11 },
    { 10, 1, 0x10 },  -- Part 10 is x=0, the drum Part at power-on
    { 16, 2, 0x1F },
  }
  for _, c in ipairs(CASES) do
    local part, value, block = c[1], c[2], c[3]
    for _, use_sysex in ipairs({ false, true }) do
      local events = PM.encode('rhythm', value, part, use_sysex)
      check(#events == 1,
        ('part %d: one message, got %d'):format(part, #events))
      check(events[1].kind == 'sysex',
        ('part %d: must be SysEx in both modes, got %s')
          :format(part, events[1].kind))

      local pl = events[1].payload
      -- 41 10 42 12 <40 1x 15> <value> <checksum>
      check(pl:byte(5) == 0x40 and pl:byte(6) == block and pl:byte(7) == 0x15,
        ('part %d: address must be 40 %02X 15, got %02X %02X %02X')
          :format(part, block, pl:byte(5), pl:byte(6), pl:byte(7)))
      check(pl:byte(8) == value,
        ('part %d: value must be %d, got %d'):format(part, value, pl:byte(8)))
    end
  end
  H.pass('Use For Rhythm writes 40 1x 15 in both modes (32 cases)')
end
