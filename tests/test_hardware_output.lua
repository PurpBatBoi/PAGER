-- Check: the hardware preview queue. Timing, batch replacement, parameter
-- coalescing, reset priority, routing errors, target capture, and framing.
--
-- The module takes its reaper table and its clock as injected dependencies,
-- so everything here runs outside REAPER against a clock this file advances
-- by hand. That is the whole reason the timing rules are testable at all:
-- real 20 ms intervals would make this suite sleep for seconds and still be
-- flaky. Nothing is copied -- the real module is required.
--
--   lua tests/test_hardware_output.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local HW = require 'hardware_output'
local check = H.check

-- A queue wired to a fake take, with a clock the test moves. `hwout` is the
-- raw I_MIDIHWOUT value: 0 is device 0 all channels, the common case.
local function rig(opts)
  opts = opts or {}
  local take = H.take(opts)
  local clock = { t = 0 }
  local q = HW.new({
    reaper = H.reaper(take),
    now = function() return clock.t end,
    interval = opts.interval or HW.INTERVAL,
  })
  return q, take, clock
end

-- Payloads are opaque to the queue; short distinct strings are enough.
local function payload(name) return name end

-- The payload of a framed message, for comparing what actually went out.
local function sent_payloads(take)
  local out = {}
  for i, s in ipairs(take.sent) do out[i] = s.msg:sub(2, -2) end
  return table.concat(out, ',')
end

-- device decoding -------------------------------------------------------------

-- I_MIDIHWOUT packs channels in the low 5 bits and the device in the next 5.
-- The mask is the point: without it, bits above the device field leak in.
check(HW.decode_device(0) == 0, 'device 0 / all channels must decode to 0')
check(HW.decode_device(32) == 1, 'device 1 must decode from 32')
check(HW.decode_device(32 + 5) == 1, 'channel bits must not reach the device')
check(HW.decode_device(31 << 5) == 31, 'device 31 is the top of the range')
check(HW.decode_device((1 << 10) | (3 << 5)) == 3,
  'bits above the device field must be masked off')
check(HW.decode_device(-1) == nil, 'a negative value means output disabled')
check(HW.decode_device(nil) == nil, 'a missing value is not a route')
H.pass('I_MIDIHWOUT decoding, including the mask and the disabled case (7 cases)')

-- framing ---------------------------------------------------------------------

-- Payloads travel unframed everywhere else, because that is the form
-- MIDI_InsertTextSysexEvt wants. Exactly one F0/F7 pair is added here.
local framed = HW.frame(string.char(0x41, 0x10))
check(framed:byte(1) == 0xF0, 'a framed message must start with F0')
check(framed:byte(-1) == 0xF7, 'a framed message must end with F7')
check(#framed == 4, 'framing must add exactly two bytes, got ' .. #framed)

local q, take = rig()
q:preview_batch({ string.char(0x41) }, take)
q:pump()
check(#take.sent == 1, 'one queued message must send once')
check(take.sent[1].msg == string.char(0xF0, 0x41, 0xF7),
  'the hardware must receive the framed message')
H.pass('F0/F7 framing is added exactly once, at the send boundary (5 cases)')

-- timing ----------------------------------------------------------------------

-- The first message of an idle queue goes out immediately; the rest are held
-- one interval apart. A batch is paced, not delayed.
local q2, take2, clock = rig()
q2:preview_batch({ payload('a'), payload('b'), payload('c') }, take2)
check(q2:pending() == 3, 'three payloads must queue as three messages')

check(q2:pump() == true, 'the first message must be due immediately')
check(#take2.sent == 1, 'exactly one message may go out per pump')

check(q2:pump() == false, 'the second must wait for the interval')
check(#take2.sent == 1, 'a too-early pump must send nothing')

clock.t = clock.t + HW.INTERVAL / 2
check(q2:pump() == false, 'half an interval is still too early')

clock.t = clock.t + HW.INTERVAL / 2
check(q2:pump() == true, 'the second must go out one interval after the first')
check(#take2.sent == 2, 'two messages must have gone out')

clock.t = clock.t + HW.INTERVAL
check(q2:pump() == true, 'the third must follow at the same spacing')
check(q2:pending() == 0, 'the queue must be empty afterwards')
check(q2:pump() == false, 'pumping an empty queue must do nothing')
check(#take2.sent == 3, 'exactly the three queued messages went out')
check(sent_payloads(take2) == 'a,b,c',
  'a batch must go out in order, got ' .. sent_payloads(take2))
H.pass('20 ms pacing: first immediate, one per pump, in order (13 cases)')

-- batch replacement -------------------------------------------------------------

-- A newer preset selection discards the unsent remainder of an older one --
-- the user has moved on from it. Messages already submitted are not recalled,
-- because they are gone.
local q3, take3, clock3 = rig()
q3:preview_batch({ payload('old1'), payload('old2'), payload('old3') }, take3)
q3:pump()                       -- old1 is out and cannot be taken back
check(#take3.sent == 1, 'the first message of the old batch went out')

q3:preview_batch({ payload('new1'), payload('new2') }, take3)
check(q3:pending() == 2, 'only the new batch may remain, got ' .. q3:pending())

clock3.t = clock3.t + HW.INTERVAL
q3:pump()
clock3.t = clock3.t + HW.INTERVAL
q3:pump()
check(sent_payloads(take3) == 'old1,new1,new2',
  'the old remainder must be discarded, got ' .. sent_payloads(take3))
H.pass('a newer preview replaces the unsent part of an older one (3 cases)')

-- A parameter edit made after a preset waits behind it rather than jumping
-- the queue, and survives a later preset replacing that batch -- it was made
-- after the preset and still describes what the user wants to hear.
local q4, take4 = rig()
q4:preview_batch({ payload('pre1'), payload('pre2') }, take4)
q4:preview_param(payload('edit'), take4, 'addr1')
check(q4:pending() == 3, 'the edit must queue behind the batch')

q4:preview_batch({ payload('newpre') }, take4)
check(q4:pending() == 2, 'the old batch goes, the edit stays')
local kinds = {}
for _, m in ipairs(q4.queue) do kinds[#kinds + 1] = m.payload end
check(table.concat(kinds, ',') == 'edit,newpre',
  'the surviving edit must keep its position, got ' .. table.concat(kinds, ','))
H.pass('parameter edits survive a preset batch being replaced (3 cases)')

-- coalescing --------------------------------------------------------------------

-- Two edits to the same address collapse to the newest value, in the original
-- position: a slider moved twice before the queue drains must send once.
local q5, take5, clock5 = rig()
q5:preview_param(payload('v1'), take5, 'addrA')
q5:preview_param(payload('other'), take5, 'addrB')
q5:preview_param(payload('v2'), take5, 'addrA')
check(q5:pending() == 2, 'the repeated address must coalesce, got ' .. q5:pending())

q5:pump()
clock5.t = clock5.t + HW.INTERVAL
q5:pump()
check(sent_payloads(take5) == 'v2,other',
  'the newest value must win in the old position, got ' .. sent_payloads(take5))

-- Different addresses never coalesce, and an edit with no address is always
-- appended -- the Master rows carry their own addressing and must not merge.
local q6, take6 = rig()
q6:preview_param(payload('x'), take6, nil)
q6:preview_param(payload('y'), take6, nil)
check(q6:pending() == 2, 'address-less edits must not coalesce')
H.pass('same-address edits coalesce to the newest value (3 cases)')

-- reset priority ------------------------------------------------------------------

-- A reset discards everything pending: the queue describes a state the reset
-- is about to throw away, so sending it first would be audible nonsense.
local q7, take7, clock7 = rig()
q7:preview_batch({ payload('a'), payload('b'), payload('c') }, take7)
q7:preview_param(payload('edit'), take7, 'addrA')
local ok7 = q7:reset(payload('GSRESET'), take7)
check(ok7 == true, 'a reset with a route must succeed')
check(q7:pending() == 1, 'a reset must be alone on the queue, got ' .. q7:pending())

q7:pump()
check(#take7.sent == 1, 'the reset went out')
check(take7.sent[1].msg:sub(2, -2) == 'GSRESET',
  'the reset must be the message that goes out')
clock7.t = clock7.t + HW.INTERVAL
q7:pump()
check(#take7.sent == 1, 'nothing may survive a reset')
H.pass('a reset cancels every pending message before queueing (5 cases)')

-- cancel drops everything and is what closing a tool does. Queued messages
-- are never written into the take -- they simply cease to exist.
local q8, take8 = rig()
q8:preview_batch({ payload('a'), payload('b') }, take8)
q8:cancel()
check(q8:pending() == 0, 'cancel must empty the queue')
q8:pump()
check(#take8.sent == 0, 'a cancelled queue must send nothing')
check(take8:count() == 0, 'cancelling must never write MIDI events')
H.pass('cancel drops the queue without writing anything (3 cases)')

-- routing errors --------------------------------------------------------------------

-- Hardware output disabled on the track: every entry point reports it and
-- queues nothing. The editor keeps the GUI value; only the send fails.
local q9, take9 = rig({ hwout = -1 })
local ok9, err9 = q9:preview_batch({ payload('a') }, take9)
check(ok9 == false, 'a disabled route must fail the batch')
check(err9 == HW.NO_ROUTE, 'the error must name the missing route, got ' .. tostring(err9))
check(q9:pending() == 0, 'a failed batch must queue nothing')

local okp, errp = q9:preview_param(payload('a'), take9, 'addrA')
check(okp == false and errp == HW.NO_ROUTE, 'a parameter edit must report the same')
check(q9:pending() == 0, 'a failed edit must queue nothing')

-- A reset with no route still cancels, and still reports the failure. The
-- editor inserts the reset into the take regardless -- the two halves are
-- independent, which is what makes the partial result reportable.
local q10, take10 = rig({ hwout = -1 })
local okr, errr = q10:reset(payload('GSRESET'), take10)
check(okr == false and errr == HW.NO_ROUTE, 'a routeless reset must report it')
check(q10:pending() == 0, 'a routeless reset queues nothing')

-- No take at all: there is no track to read a route from.
local q11 = rig()
local okt, errt = q11:preview_batch({ payload('a') }, nil)
check(okt == false and errt == HW.NO_TAKE, 'a missing take must be named, got ' .. tostring(errt))
H.pass('routing failures report and queue nothing (9 cases)')

-- target capture -------------------------------------------------------------------

-- The device is resolved when a batch is queued and stored on each message,
-- so changing the selected take mid-batch cannot redirect the remainder.
-- Without this, half a run would land on a different synth.
local take_a = H.take({ hwout = 0 })         -- device 0
local take_b = H.take({ hwout = 3 << 5 })    -- device 3
local clock12 = { t = 0 }
local R12 = H.reaper(take_a)
-- One reaper table, whichever take is asked about -- the route comes from the
-- take passed in, which is exactly what capture has to make irrelevant later.
R12.GetMediaItemTake_Track = function(t) return t end
R12.GetMediaTrackInfo_Value = function(track) return track.hwout end
R12.SendMIDIMessageToHardware = function(dev, msg)
  take_a.sent[#take_a.sent + 1] = { dev = dev, msg = msg }
end
local q12 = HW.new({ reaper = R12, now = function() return clock12.t end })

q12:preview_batch({ payload('a'), payload('b') }, take_a)
q12:pump()                                   -- first goes to device 0
q12:preview_param(payload('c'), take_b, 'addrA')  -- a later edit targets device 3
clock12.t = clock12.t + HW.INTERVAL
q12:pump()
clock12.t = clock12.t + HW.INTERVAL
q12:pump()

check(#take_a.sent == 3, 'all three messages must go out')
check(take_a.sent[1].dev == 0, 'the batch must go to the captured device')
check(take_a.sent[2].dev == 0,
  'the rest of the batch must keep the device captured when it was queued')
check(take_a.sent[3].dev == 3, 'the later edit must use its own captured device')
H.pass('the device is captured per message when queued (4 cases)')

-- The queue is not the take: nothing above wrote a MIDI event anywhere.
check(take2:count() == 0 and take3:count() == 0 and take7:count() == 0,
  'the hardware queue must never write into a MIDI take')
H.pass('hardware previews never touch the MIDI take (1 case)')

-- typed events: framing per kind ------------------------------------------------

-- Everything above this line predates the Part Editor and must keep passing
-- unchanged: SysEx payloads travel without F0/F7 and are framed exactly once
-- at the send boundary. Part previews add channel messages, which are already
-- complete and must go out untouched -- an F0 in front of a Control Change is
-- a different message, and the hardware would simply ignore it.

-- The raw bytes of a channel message. Status nibble, zero-based channel.
local cc_bytes = HW.channel_bytes(0xB0, 0, 74, 84)
check(#cc_bytes == 3, 'a Control Change is three bytes, got ' .. #cc_bytes)
check(cc_bytes:byte(1) == 0xB0, 'channel 0 Control Change status must be B0')
check(cc_bytes:byte(2) == 74 and cc_bytes:byte(3) == 84, 'cc number then value')
check(HW.channel_bytes(0xB0, 15, 7, 100):byte(1) == 0xBF,
  'channel 15 must land in the low nibble')

-- Two-byte messages exist too; the third byte is simply absent rather than 0.
check(#HW.channel_bytes(0xC0, 3, 42) == 2, 'a two-byte message stays two bytes')

-- encode_event turns one part_messages event into a payload and a kind.
local pay_cc, kind_cc = HW.encode_event({ kind = 'cc', channel = 9, cc = 7, value = 100 })
check(kind_cc == HW.CHANNEL, 'a cc event must be a channel message')
check(pay_cc == string.char(0xB9, 7, 100), 'part 10 level must encode to B9 07 64')

local pay_sx, kind_sx = HW.encode_event({ kind = 'sysex', payload = 'RAW' })
check(kind_sx == HW.SYSEX, 'a sysex event must stay sysex')
check(pay_sx == 'RAW', 'a sysex payload must pass through unchanged')

-- A channel message goes out raw; a SysEx one goes out framed. Same queue,
-- same pump, different boundary treatment.
local q13, take13, clock13 = rig()
q13:preview_events({ { kind = 'cc', channel = 0, cc = 74, value = 84 } }, take13, 'cutoff')
q13:pump()
check(#take13.sent == 1, 'the channel message must go out')
check(take13.sent[1].msg == string.char(0xB0, 74, 84),
  'a channel message must not be framed')

q13:preview_events({ { kind = 'sysex', payload = 'SX' } }, take13, 'eq')
clock13.t = clock13.t + HW.INTERVAL
q13:pump()
check(take13.sent[2].msg == string.char(0xF0) .. 'SX' .. string.char(0xF7),
  'a sysex event must still be framed exactly once')
H.pass('typed events: channel messages raw, SysEx framed (11 cases)')

-- ordered runs -------------------------------------------------------------------

-- An RPN is a run: selector, Data Entry, Null. It must reach the hardware in
-- that order and must never be coalesced internally -- a Null arriving before
-- its Data Entry writes nothing at all.
local function rpn_events(value)
  return {
    { kind = 'cc', channel = 0, cc = 101, value = 0 },
    { kind = 'cc', channel = 0, cc = 100, value = 0 },
    { kind = 'cc', channel = 0, cc = 6, value = value },
    { kind = 'cc', channel = 0, cc = 101, value = 127 },
    { kind = 'cc', channel = 0, cc = 100, value = 127 },
  }
end

local q14, take14, clock14 = rig()
q14:preview_events(rpn_events(2), take14, 'bend_range')
check(q14:pending() == 5, 'a five-message run must queue as five, got ' .. q14:pending())

for _ = 1, 5 do
  q14:pump()
  clock14.t = clock14.t + HW.INTERVAL
end
check(#take14.sent == 5, 'every message of the run must go out')
local seq = {}
for i, s in ipairs(take14.sent) do
  seq[i] = ('%d=%d'):format(s.msg:byte(2), s.msg:byte(3))
end
check(table.concat(seq, ',') == '101=0,100=0,6=2,101=127,100=127',
  'the run must go out in order, got ' .. table.concat(seq, ','))
H.pass('an ordered run keeps its order through the queue (3 cases)')

-- The messages of a run share an addr but must not coalesce with each other:
-- three of these five carry a repeated controller number.
local q15, take15 = rig()
q15:preview_events(rpn_events(2), take15, 'bend_range')
check(q15:pending() == 5, 'a run must not coalesce within itself')

-- A newer edit to the SAME parameter replaces the whole run rather than
-- rewriting one message of it, so the queue never holds the selector of one
-- value in front of the Data Entry of another.
q15:preview_events(rpn_events(7), take15, 'bend_range')
check(q15:pending() == 5, 'the run must be replaced whole, got ' .. q15:pending())
local vals = {}
for _, m in ipairs(q15.queue) do vals[#vals + 1] = m.payload:byte(3) end
check(table.concat(vals, ',') == '0,0,7,127,127',
  'only the newest run may remain, got ' .. table.concat(vals, ','))

-- A different parameter's run is untouched by that replacement.
q15:preview_events(rpn_events(1), take15, 'fine_tune')
check(q15:pending() == 10, 'two parameters means two runs, got ' .. q15:pending())
q15:preview_events(rpn_events(9), take15, 'bend_range')
check(q15:pending() == 10, 'replacing one run must not disturb the other')
H.pass('a run is replaced whole, and only its own parameter (5 cases)')

-- cross-encoding replacement ----------------------------------------------------

-- Use SysEx? changes the shape of a parameter's encoding, not its identity.
-- The coalescing rule is by logical parameter, so a newer edit replaces its
-- unsent predecessor across that change in both directions.

-- run replaced by a single message
local q16, take16 = rig()
q16:preview_events(rpn_events(2), take16, 'bend_range')
q16:preview_events({ { kind = 'sysex', payload = 'DT1BEND' } }, take16, 'bend_range')
check(q16:pending() == 1, 'a run must be fully replaced by a single message, got '
  .. q16:pending())
check(q16.queue[1].payload == 'DT1BEND', 'the newest encoding must be what remains')
check(q16.queue[1].kind == HW.SYSEX, 'the kind must follow the new encoding')

-- single message replaced by a run
local q17, take17 = rig()
q17:preview_events({ { kind = 'sysex', payload = 'DT1BEND' } }, take17, 'bend_range')
q17:preview_events(rpn_events(2), take17, 'bend_range')
check(q17:pending() == 5, 'a single message must be fully replaced by a run, got '
  .. q17:pending())
for _, m in ipairs(q17.queue) do
  check(m.kind == HW.CHANNEL, 'nothing of the old SysEx encoding may survive')
end

-- single replaced by single, in place: the position the earlier edit earned
-- in the queue is kept, exactly as it is for the Effects Editor's payloads.
local q18, take18 = rig()
q18:preview_events({ { kind = 'cc', channel = 0, cc = 74, value = 10 } }, take18, 'cutoff')
q18:preview_events({ { kind = 'cc', channel = 0, cc = 71, value = 20 } }, take18, 'resonance')
q18:preview_events({ { kind = 'cc', channel = 0, cc = 74, value = 99 } }, take18, 'cutoff')
check(q18:pending() == 2, 'the repeated parameter must coalesce, got ' .. q18:pending())
check(q18.queue[1].payload:byte(3) == 99, 'the newest value must win')
check(q18.queue[2].payload:byte(3) == 20, 'in the original position')
H.pass('previews coalesce by logical parameter across encoding changes (9 cases)')

-- A run queued behind a preset batch still waits its turn rather than jumping
-- it, and survives that batch being replaced -- the same rule the Effects
-- Editor's single payloads already follow.
local q19, take19 = rig()
q19:preview_batch({ payload('pre1'), payload('pre2') }, take19)
q19:preview_events(rpn_events(2), take19, 'bend_range')
check(q19:pending() == 7, 'the run must queue behind the batch')
q19:preview_batch({ payload('newpre') }, take19)
check(q19:pending() == 6, 'the old batch goes, the whole run stays')
check(q19.queue[1].payload:byte(2) == 101, 'the run must keep its position and order')
check(q19.queue[6].payload == 'newpre', 'the new batch follows it')
H.pass('a run survives a preset batch being replaced (4 cases)')

-- routing and cancellation apply to runs exactly as to single messages.
local q20, take20 = rig({ hwout = -1 })
local ok20, err20 = q20:preview_events(rpn_events(2), take20, 'bend_range')
check(ok20 == false and err20 == HW.NO_ROUTE, 'a routeless run must report it')
check(q20:pending() == 0, 'a failed run must queue nothing')

local ok21, err21 = q20:preview_events({}, take20, 'bend_range')
check(ok21 == false and err21 == HW.NO_ROUTE,
  'an empty list must still report a missing route before succeeding')

local q22, take22 = rig()
check(q22:preview_events({}, take22, 'bend_range') == true,
  'an empty event list with a route is a no-op, not a failure')
check(q22:pending() == 0, 'an empty list queues nothing')

local q23, take23 = rig()
q23:preview_events(rpn_events(2), take23, 'bend_range')
q23:cancel()
check(q23:pending() == 0, 'cancel must drop a run like anything else')
check(take23:count() == 0, 'previewing a run must never write MIDI events')
H.pass('runs honour routing, empty lists and cancellation (7 cases)')

-- The Effects Editor's own entry point is untouched by all of the above: its
-- payloads still queue as SysEx and still frame at the boundary.
local q24, take24 = rig()
q24:preview_param(payload('legacy'), take24, 'addrA')
check(q24.queue[1].kind == HW.SYSEX, 'preview_param must default to SysEx')
q24:pump()
check(take24.sent[1].msg == string.char(0xF0) .. 'legacy' .. string.char(0xF7),
  'the existing SysEx path must still be framed')
H.pass('the pre-existing SysEx API is unchanged (2 cases)')

-- coalescing is per DEVICE as well as per target -----------------------------
--
-- Plan 001. The queue's identity for a pending parameter edit is the pair
-- (resolved device, logical key), not the key alone.
--
-- Two things made the old key-only rule wrong at once. A track's hardware
-- output selects which SC-8850 Part Group the messages reach, so the same
-- logical key on two devices is two different physical destinations and
-- discarding one for the other silently drops an edit the user made. And the
-- Part Editor passed a bare parameter id, so an edit on Part 2 replaced an
-- unsent edit to the same control on Part 1 -- the keys were equal because
-- the Part was nowhere in them.
--
-- Nothing here changes pacing, ordering or run handling; only what counts as
-- "the same pending edit".

-- A rig whose device comes from the take itself, so one queue can be driven
-- against two destinations the way two routed tracks would.
local function multi_rig()
  local sent = {}
  local clock = { t = 0 }
  local R = H.reaper(H.take())
  R.GetMediaItemTake_Track = function(t) return t end
  R.GetMediaTrackInfo_Value = function(track) return track.hwout end
  R.SendMIDIMessageToHardware = function(dev, msg)
    sent[#sent + 1] = { dev = dev, msg = msg }
  end
  local q = HW.new({ reaper = R, now = function() return clock.t end })
  -- `hwout` packs the device in the bits above the channels, so device n is
  -- n << 5 -- the same encoding I_MIDIHWOUT uses.
  local function take_on(dev) return { hwout = dev << 5 } end
  return q, take_on, sent, clock
end

local function cc_ev(cc, value)
  return { { kind = 'cc', channel = 0, cc = cc, value = value } }
end

local function sx_ev(payload)
  return { { kind = 'sysex', payload = payload } }
end

-- Same key, same device: coalesces, exactly as before.
do
  local q, take_on = multi_rig()
  local a = take_on(0)
  q:preview_events(cc_ev(74, 10), a, 'part:1:cutoff')
  q:preview_events(cc_ev(74, 99), a, 'part:1:cutoff')
  check(q:pending() == 1,
    'one key on one device must still coalesce, got ' .. q:pending())
  check(q.queue[1].payload:byte(3) == 99, 'the newest value must win')
end

-- Same key, two devices: two pending entries. The second destination has
-- heard nothing yet, so there is nothing there to replace.
do
  local q, take_on, sent, clock = multi_rig()
  local a, b = take_on(0), take_on(3)
  q:preview_events(cc_ev(74, 10), a, 'part:1:cutoff')
  q:preview_events(cc_ev(74, 99), b, 'part:1:cutoff')
  check(q:pending() == 2,
    'the same key on two devices must not coalesce, got ' .. q:pending())
  check(q.queue[1].dev == 0 and q.queue[2].dev == 3,
    'each entry must keep its own resolved device')

  -- And both actually go out, to their own destinations.
  q:pump()
  clock.t = clock.t + HW.INTERVAL
  q:pump()
  check(#sent == 2, 'both must be sent, got ' .. #sent)
  check(sent[1].dev == 0 and sent[2].dev == 3,
    'each must reach the device it was queued for')
  check(sent[1].msg:byte(3) == 10 and sent[2].msg:byte(3) == 99,
    'and each must carry its own value')
end

-- A third edit on the first device replaces only that device's entry.
do
  local q, take_on = multi_rig()
  local a, b = take_on(0), take_on(3)
  q:preview_events(cc_ev(74, 10), a, 'part:1:cutoff')
  q:preview_events(cc_ev(74, 20), b, 'part:1:cutoff')
  q:preview_events(cc_ev(74, 30), a, 'part:1:cutoff')
  check(q:pending() == 2, 'still one entry per device, got ' .. q:pending())
  check(q.queue[1].dev == 0 and q.queue[1].payload:byte(3) == 30,
    'the first device must take the newest value in its original position')
  check(q.queue[2].dev == 3 and q.queue[2].payload:byte(3) == 20,
    'the other device must be untouched')
end

-- Two Parts are two logical targets. This is the bug the Part-scoped keys
-- fix: before them, both edits carried the id 'cutoff' and the second threw
-- the first away.
do
  local q, take_on = multi_rig()
  local a = take_on(0)
  q:preview_events(cc_ev(74, 10), a, 'part:1:cutoff')
  q:preview_events(cc_ev(74, 99), a, 'part:2:cutoff')
  check(q:pending() == 2,
    'two Parts must not coalesce, got ' .. q:pending())
  check(q.queue[1].payload:byte(3) == 10 and q.queue[2].payload:byte(3) == 99,
    'each Part must keep its own pending value')
end

-- Drum keys carry map, note and parameter. Any of the three differing is a
-- different logical target; all three matching is the same one.
do
  local q, take_on = multi_rig()
  local a = take_on(0)

  q:preview_events(sx_ev('m1n60lvl-a'), a, 'drum:1:60:level')
  q:preview_events(sx_ev('m1n60lvl-b'), a, 'drum:1:60:level')
  check(q:pending() == 1, 'the same drum target must coalesce, got ' .. q:pending())
  check(q.queue[1].payload == 'm1n60lvl-b', 'to the newest value')

  q:preview_events(sx_ev('m2n60lvl'), a, 'drum:2:60:level')
  check(q:pending() == 2, 'the other MAP is a different target')
  q:preview_events(sx_ev('m1n61lvl'), a, 'drum:1:61:level')
  check(q:pending() == 3, 'another NOTE is a different target')
  q:preview_events(sx_ev('m1n60pan'), a, 'drum:1:60:pan')
  check(q:pending() == 4, 'another PARAMETER is a different target')

  -- And the same drum target on another device is still its own entry.
  local b = take_on(3)
  q:preview_events(sx_ev('m1n60lvl-c'), b, 'drum:1:60:level')
  check(q:pending() == 5, 'the same drum target on another device must not coalesce')
  check(q.queue[1].payload == 'm1n60lvl-b',
    'and must not disturb the first device')
end

-- A multi-message run still replaces whole and stays ordered, and a run on
-- another device is a separate run rather than a replacement.
do
  local q, take_on = multi_rig()
  local a, b = take_on(0), take_on(3)
  q:preview_events(rpn_events(2), a, 'part:1:bend_range')
  check(q:pending() == 5, 'a run queues whole, got ' .. q:pending())
  q:preview_events(rpn_events(9), b, 'part:1:bend_range')
  check(q:pending() == 10,
    'the same run on another device must not replace it, got ' .. q:pending())
  q:preview_events(rpn_events(7), a, 'part:1:bend_range')
  check(q:pending() == 10,
    'replacing one device run must leave the other, got ' .. q:pending())

  -- The surviving run stays whole and contiguous, and the replacement is
  -- appended after it rather than interleaved.
  local devs = {}
  for _, m in ipairs(q.queue) do devs[#devs + 1] = m.dev end
  check(table.concat(devs, ',') == '3,3,3,3,3,0,0,0,0,0',
    'runs must stay whole and ordered, got ' .. table.concat(devs, ','))

  -- Ordering inside the replacement is untouched: the run still ends on the
  -- two RPN Null messages, CC101 then CC100, both 127.
  check(q.queue[9].payload:byte(2) == 101 and q.queue[9].payload:byte(3) == 127,
    'the replacement run must still close with RPN Null MSB')
  check(q.queue[10].payload:byte(2) == 100 and q.queue[10].payload:byte(3) == 127,
    'and then RPN Null LSB')
end
H.pass('coalescing is keyed by resolved device and logical target (24 cases)')

-- preview_param, the Effects Editor's path, follows the same rule: its addr
-- is a logical key too, and two devices are two destinations.
do
  local q, take_on = multi_rig()
  local a, b = take_on(0), take_on(3)
  q:preview_param(payload('v1'), a, 'addrA')
  q:preview_param(payload('v2'), a, 'addrA')
  check(q:pending() == 1, 'one device still coalesces, got ' .. q:pending())
  q:preview_param(payload('v3'), b, 'addrA')
  check(q:pending() == 2,
    'the same addr on another device must not coalesce, got ' .. q:pending())
  check(q.queue[1].payload == 'v2' and q.queue[1].dev == 0,
    'the first device keeps its newest value')
  check(q.queue[2].payload == 'v3' and q.queue[2].dev == 3,
    'the second device gets its own entry')
end
H.pass('preview_param is device-scoped too (4 cases)')
