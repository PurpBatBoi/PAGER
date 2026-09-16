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
