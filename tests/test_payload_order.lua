-- Characterization: the bytes that go out, and the order they go out in.
--
-- Phase 3 consolidates preset construction so the automatic hardware preview
-- and the MIDI insertion consume one ordered list instead of two parallel
-- walks. That is only safe if the order and the encoding are pinned first --
-- a drift between them is silent, because either sequence alone still looks
-- plausible.
--
-- This pins three things the refactor must not change:
--   the DT1 framing and checksum of a parameter event,
--   the F0/F7 framing added at the hardware boundary (and nowhere else),
--   the event order a full insertion-effect run is written in.
--
-- The encoders are the real gs_sysex.lua, the hardware boundary is the real
-- hardware_output.lua, and the run builders are lifted out of
-- effects_editor.lua.
--   lua tests/test_payload_order.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local GS = require 'gs_sysex'
local HW = require 'hardware_output'
local EFX_PARAMS = require 'efx_params'
local check = H.check

local dt1 = GS.dt1

-- DT1 framing: 41 <dev> 42 12, three address bytes, the data byte, checksum.
-- Item events carry exactly this, with no F0/F7 -- REAPER supplies those for
-- the item lane, which is why MIDI_InsertTextSysexEvt is given the bare
-- payload with type -1.
do
  local p = dt1({ 0x40, 0x03, 0x00, 0x05 })
  check(#p == 9, 'a one-parameter DT1 payload is 9 bytes, got ' .. #p)
  check(p:byte(1) == 0x41, 'Roland ID')
  check(p:byte(3) == 0x42, 'GS model ID')
  check(p:byte(4) == 0x12, 'DT1 command')
  check(p:byte(5) == 0x40 and p:byte(6) == 0x03 and p:byte(7) == 0x00,
    'the three address bytes follow the command')
  check(p:byte(8) == 0x05, 'then the data byte')
  check(p:byte(1) ~= 0xF0 and p:byte(-1) ~= 0xF7,
    'an item payload must carry no F0/F7 -- REAPER adds them')

  -- The checksum is over address+data, and it is what the device rejects a
  -- message on, so it is pinned against the manual's own worked example.
  check(dt1({ 0x40, 0x01, 0x30, 0x02 }):byte(-1) == 0x0D,
    'manual p.245 example checksum must be 0x0D')
end

-- The hardware boundary adds exactly one F0 and one F7 around that same
-- payload. Phase 3 moved this out of the editor into hardware_output.lua;
-- the bytes on the wire come out identical, which is what is checked here.
do
  local take = H.take({ hwout = 0 })
  local hw = HW.new({ reaper = H.reaper(take), now = function() return 0 end })

  local payload = dt1({ 0x40, 0x03, 0x00, 0x05 })
  local ok = hw:preview_param(payload, take)
  check(ok, 'a track with hardware output must accept the send')
  hw:pump()
  check(#take.sent == 1, 'one message went out, got ' .. #take.sent)

  local msg = take.sent[1].msg
  check(msg:byte(1) == 0xF0, 'the framed message opens with F0')
  check(msg:byte(-1) == 0xF7, 'the framed message closes with F7')
  check(msg:sub(2, -2) == payload, 'the payload between them is unchanged')
  check(#msg == #payload + 2, 'exactly one byte is added at each end')
end

-- I_MIDIHWOUT is the route. Negative means hardware output is disabled, and
-- the device is the value shifted right by 5 -- decoding this wrong sends a
-- correct message to the wrong unit, which no byte-level check would catch.
do
  local take = H.take({ hwout = 0 })
  local hw = HW.new({ reaper = H.reaper(take), now = function() return 0 end })

  take.hwout = -1
  local ok, err = hw:preview_param(dt1({ 0x40, 0x03, 0x00, 0x05 }), take)
  check(ok == false, 'a disabled hardware output must not report success')
  check(err and err:find('hardware output'), 'the error must name the cause, got ' .. tostring(err))
  hw:pump()
  check(#take.sent == 0, 'nothing may go out when the route is disabled')

  take.hwout = 3 << 5
  hw:preview_param(dt1({ 0x40, 0x03, 0x00, 0x05 }), take)
  hw:pump()
  check(take.sent[1].dev == 3,
    'the device is (hwout >> 5) & 0x1F, got ' .. tostring(take.sent[1].dev))
end

-- A full insertion-effect run: every ps parameter in table order, then every
-- EFX_SUB parameter, all on the 40 03 address space. This is the order Phase 3
-- must reproduce from one shared list for both the preview and the insertion,
-- including the shared Insertion Sub values at the end.
do
  local env = { math = math, tonumber = tonumber, ipairs = ipairs }
  local EFX_SUB = assert(load(H.table_body('EFX_SUB') .. '\nreturn EFX_SUB',
                              'EFX_SUB', 't', env))()
  local clamp = H.lift({ 'clamp' }, env)

  local ps = EFX_PARAMS[2] -- 11 real parameters
  check(#ps == 11, 'this test assumes EFX type 2 has 11 parameters')

  -- Rebuild the event list insert_efx_preset builds, from a preset whose
  -- values are each parameter's default.
  local vals, sub = {}, {}
  for i, e in ipairs(ps) do vals[i] = e.default end
  for i, e in ipairs(EFX_SUB) do sub[i] = e.default end

  local events = {}
  for i, e in ipairs(ps) do
    events[#events + 1] = { addr = { 0x40, 0x03, e.addr },
                            value = clamp(math.floor(vals[i]), e.min, e.max) }
  end
  for i, e in ipairs(EFX_SUB) do
    events[#events + 1] = { addr = { 0x40, 0x03, e.addr },
                            value = clamp(math.floor(sub[i]), e.min, e.max) }
  end

  check(#events == #ps + #EFX_SUB,
    'a complete run is every parameter plus every sub value, got ' .. #events)
  for i, e in ipairs(events) do
    check(e.addr[1] == 0x40 and e.addr[2] == 0x03,
      'event ' .. i .. ' must address the insertion block 40 03')
    check(e.value >= 0 and e.value <= 127,
      'event ' .. i .. ' value ' .. e.value .. ' does not fit a MIDI data byte')
  end
  for i = 1, #ps do
    check(events[i].addr[3] == ps[i].addr,
      'parameter ' .. i .. ' must keep its table position in the run')
  end
  for i = 1, #EFX_SUB do
    check(events[#ps + i].addr[3] == EFX_SUB[i].addr,
      'sub value ' .. i .. ' must follow every parameter, in its own order')
  end
end

-- Reset messages. GS Reset is a DT1; GM1/GM2 are Universal Non-realtime, with
-- no device ID and no checksum, so they must not be run through dt1(). Phase 3
-- makes resets both send and insert, so both paths carry these same bytes.
do
  local env = { string = string, dt1 = dt1, GS = GS }
  local RESETS = assert(load(H.table_body('RESETS') .. '\nreturn RESETS',
                             'RESETS', 't', env))()
  check(#RESETS == 3, 'three resets: GS, GM1, GM2')

  local by_name = {}
  for _, r in ipairs(RESETS) do by_name[r.name] = r.build() end

  local gs = by_name['GS Reset']
  check(gs:byte(1) == 0x41 and gs:byte(4) == 0x12, 'GS Reset is a DT1 message')
  check(gs:byte(-1) == 0x41, 'GS Reset checksum must be 0x41')

  for _, name in ipairs({ 'GM1 Reset', 'GM2 Reset' }) do
    local m = by_name[name]
    check(m:byte(1) == 0x7E, name .. ' is Universal Non-realtime (7E)')
    check(m:byte(2) == 0x7F, name .. ' is broadcast (7F)')
    check(m:byte(3) == 0x09, name .. ' is a General MIDI message')
    check(#m == 4, name .. ' carries no checksum, so it is 4 bytes, got ' .. #m)
  end
  check(by_name['GM1 Reset']:byte(4) == 0x01, 'GM1 is sub-ID 01')
  check(by_name['GM2 Reset']:byte(4) == 0x03, 'GM2 is sub-ID 03')
end

H.pass('payload order: DT1 framing, F0/F7 boundary, route decoding, run order, resets (5 groups)')
