-- Plan 001, step 1: canonical drum values to wire bytes.
--
-- Every drum control, on both maps, at both range endpoints, asserted as
-- exact bytes. This is the layer where a wrong offset or a transposed nibble
-- is completely silent -- the panel still reads right, the take still
-- contains an event, and only the hardware disagrees.
--
-- The three payloads at the top are written out LONGHAND, checksum included,
-- from the SC-8850 manual through plan 001's protocol oracle. They do not go
-- through gs_sysex at all: an expectation built with the production checksum
-- would agree with a broken one. The bulk assertions below do use GS.dt1,
-- because by then the checksum itself is pinned and what is being tested is
-- the address and the value conversion.
--   lua tests/test_drum_messages.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local GS = require 'gs_sysex'
local D = require 'drum_params'
local DM = require 'drum_messages'
local check = H.check

-- readable failures ------------------------------------------------------------

local function hex(s)
  local out = {}
  for i = 1, #s do out[i] = ('%02X'):format(s:byte(i)) end
  return table.concat(out, ' ')
end

-- One encoded edit, rendered as its single SysEx payload. Every drum control
-- is one DT1 write, so anything else here is a failure in itself.
local function enc(id, value, mode, note)
  local events = DM.encode(id, value, mode, note)
  check(#events == 1,
    ('%s must encode to exactly one event, got %d'):format(id, #events))
  local e = events[1]
  check(e.kind == 'sysex', id .. ' must encode as SysEx, got ' .. tostring(e.kind))
  return hex(e.payload), e
end

-- the literal payloads ----------------------------------------------------------

-- Written out by hand from the manual: Roland ID, device 10H, model 42H,
-- command DT1 12H, then the three address bytes, the data byte and the
-- checksum. Nothing below this line is derived from the module it checks.
local LITERAL = {
  { id = 'level', value = 100, mode = 1, note = 75,
    want = '41 10 42 12 41 02 4B 64 0E',
    what = 'DRUM 1 Level, note 75, value 100' },
  { id = 'pan', value = 0, mode = 1, note = 60,
    want = '41 10 42 12 41 04 3C 40 3F',
    what = 'DRUM 1 Pan, note 60, canonical centre 0 (wire 40)' },
  { id = 'delay', value = 127, mode = 2, note = 127,
    want = '41 10 42 12 41 19 7F 7F 28',
    what = 'DRUM 2 Delay, note 127, value 127' },
}
for _, c in ipairs(LITERAL) do
  local got = enc(c.id, c.value, c.mode, c.note)
  check(got == c.want, ('%s: got %s, expected %s'):format(c.what, got, c.want))
end
H.pass('the three manual-derived payloads encode byte for byte (3 cases)')

-- the address travels with the event -----------------------------------------------

-- Insertion matches a previous write by its COMPLETE three-byte address, so
-- the address has to be attached to the event rather than recovered by
-- re-deriving it. It must also agree with what is actually inside the payload
-- -- an addr that says one thing while the bytes say another would make
-- replacement delete the wrong event and look like it worked.
do
  local _, e = enc('level', 100, 1, 75)
  check(type(e.addr) == 'table' and #e.addr == 3,
    'the event must carry its complete three-byte address')
  check(e.addr[1] == 0x41 and e.addr[2] == 0x02 and e.addr[3] == 0x4B,
    ('addr is %02X %02X %02X, expected 41 02 4B')
      :format(e.addr[1], e.addr[2], e.addr[3]))

  local inside = GS.dt1_addr_of(e.payload)
  check(inside and inside[1] == e.addr[1] and inside[2] == e.addr[2]
        and inside[3] == e.addr[3],
    'the attached address must match the bytes in the payload')

  -- Both maps, both note endpoints, every parameter: the attached address
  -- must always be the one the metadata describes.
  for _, mode in ipairs({ 1, 2 }) do
    for _, note in ipairs({ 0, 60, 127 }) do
      for _, p in ipairs(D.PARAMS) do
        local _, ev = enc(p.id, p.min, mode, note)
        check(ev.addr[1] == 0x41, p.id .. ': the drum block is 41')
        check(ev.addr[2] == (mode - 1) * 0x10 + p.nibble,
          ('%s on map %d: middle byte %02X, expected %02X')
            :format(p.id, mode, ev.addr[2], (mode - 1) * 0x10 + p.nibble))
        check(ev.addr[3] == note,
          p.id .. ': the note must be the third address byte')
      end
    end
  end
end
H.pass('one edit is one SysEx event carrying its complete address (60 cases)')

-- value conversion ---------------------------------------------------------------

-- The expected payload for an address and one data byte, built through
-- gs_sysex now that the checksum itself is pinned above. What is being
-- checked from here on is which address and which byte, not the arithmetic.
local function want_dt1(mode, nibble, note, data)
  return hex(GS.dt1({ 0x41, (mode - 1) * 0x10 + nibble, note, data }))
end

-- Pan is the one row whose canonical value is not its wire byte: -64..+63
-- becomes 00H..40H..7FH, so -64 is the hardware's Random and 0 is centre.
local PAN_CASES = {
  { -64, 0x00, 'Random' },
  { -63, 0x01, 'hard left' },
  { -1,  0x3F, 'one left of centre' },
  { 0,   0x40, 'centre' },
  { 1,   0x41, 'one right of centre' },
  { 63,  0x7F, 'hard right' },
}
for _, c in ipairs(PAN_CASES) do
  for _, mode in ipairs({ 1, 2 }) do
    local got = enc('pan', c[1], mode, 38)
    local want = want_dt1(mode, 4, 38, c[2])
    check(got == want, ('pan %d (%s) on map %d: got %s, expected %s')
      :format(c[1], c[3], mode, got, want))
  end
end

-- Pitch is PLAY NOTE NUMBER: the panel's value is relative to a neutral 60
-- and the wire field is the absolute sample pitch, so the byte is the value
-- plus 60. The endpoints are what pin the shift -- -60 is wire 0 and +67 is
-- wire 127, the full 00..7F the manual documents.
local PITCH_CASES = {
  { -60, 0x00, 'the bottom of the wire range' },
  { -7,  53,   'the toms, which all store 53' },
  { 0,   60,   'neutral, which the panel shows as 0' },
  { 12,  72,   'MC-500 Beep 1' },
  { 67,  127,  'the top of the wire range' },
}
for _, c in ipairs(PITCH_CASES) do
  for _, mode in ipairs({ 1, 2 }) do
    local got = enc('pitch', c[1], mode, 24)
    local want = want_dt1(mode, 1, 24, c[2])
    check(got == want, ('pitch %d (%s) on map %d: got %s, expected %s')
      :format(c[1], c[3], mode, got, want))
  end
end

-- Every remaining row is sent unchanged, at both ends of its range, on both
-- maps and at both note endpoints. Pan and Pitch are excluded: they are the
-- two rows whose canonical value is not their wire byte, and both are pinned
-- above.
for _, p in ipairs(D.PARAMS) do
  if p.id ~= 'pan' and p.id ~= 'pitch' then
    for _, value in ipairs({ p.min, p.max }) do
      for _, mode in ipairs({ 1, 2 }) do
        for _, note in ipairs({ 0, 127 }) do
          local got = enc(p.id, value, mode, note)
          local want = want_dt1(mode, p.nibble, note, value)
          check(got == want,
            ('%s = %d on map %d note %d: got %s, expected %s')
              :format(p.id, value, mode, note, got, want))
        end
      end
    end
  end
end

-- The two switches are 0 and 1 on the wire, not 0 and 127: a drum Rx switch
-- is a one-bit field, and 127 would be out of its documented range.
for _, id in ipairs({ 'rx_note_on', 'rx_note_off' }) do
  local p = D.BY_ID[id]
  check(enc(id, 0, 1, 60) == want_dt1(1, p.nibble, 60, 0), id .. ' off is 00')
  check(enc(id, 1, 1, 60) == want_dt1(1, p.nibble, 60, 1), id .. ' on is 01')
end

-- Chorus and Delay are both kept and both sendable. The manual says the
-- hardware honours whichever was written last, which is a hardware fact, not
-- a reason for the encoder to zero the other field -- doing so would discard
-- an edit the user made and never asked to undo.
do
  local cho = enc('chorus', 100, 1, 42)
  local dly = enc('delay', 80, 1, 42)
  check(cho == want_dt1(1, 6, 42, 100), 'chorus encodes its own value alone')
  check(dly == want_dt1(1, 9, 42, 80), 'delay encodes its own value alone')
  check(cho ~= dly, 'the two must not collapse to one address')
end
H.pass('values convert per row: Pan offsets, everything else unchanged (86 cases)')

-- rejection ------------------------------------------------------------------------

-- Invalid input must be REJECTED, not wrapped with a bitwise mask. A masked
-- 128 becomes 0 and writes a real value to a real address, which is a silent
-- wrong edit; an error is a visible one.
local BAD = {
  { 'nonesuch', 0, 1, 60, 'an unknown parameter id' },
  { 'level', 128, 1, 60, 'a value above the range' },
  { 'level', -1, 1, 60, 'a value below the range' },
  { 'pan', 64, 1, 60, 'a pan above +63' },
  { 'pan', -65, 1, 60, 'a pan below -64' },
  { 'rx_note_on', 2, 1, 60, 'a switch above 1' },
  { 'level', 'x', 1, 60, 'a non-numeric value' },
  { 'level', 0/0, 1, 60, 'NaN' },
  { 'level', 64, 0, 60, 'map 0' },
  { 'level', 64, 3, 60, 'map 3' },
  { 'level', 64, nil, 60, 'a missing map' },
  { 'level', 64, 1, -1, 'note -1' },
  { 'level', 64, 1, 128, 'note 128' },
  { 'level', 64, 1, 60.5, 'a fractional note' },
  { 'level', 64, 1, nil, 'a missing note' },
  { 'level', 64, 1, 'x', 'a non-numeric note' },
}
for _, c in ipairs(BAD) do
  local ok = pcall(DM.encode, c[1], c[2], c[3], c[4])
  check(not ok, c[5] .. ' must be rejected, not encoded')
end

-- A rejected value must not have reached the byte conversion first: nothing
-- partial is emitted, and the error is the only result.
do
  local ok, err = pcall(DM.encode, 'level', 999, 1, 60)
  check(not ok and type(err) == 'string', 'a rejection must carry a message')
end
H.pass('invalid ids, maps, notes and values are rejected, never masked (17 cases)')

H.pass('drum_messages: literal payloads, both maps, every endpoint')
