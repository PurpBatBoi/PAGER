-- Phase 4: writing one Part parameter into the take, and replacing what was
-- already there.
--
-- The dangerous half of this phase is the removal, not the insertion. A
-- replacement that matches too loosely deletes a neighbouring parameter, an
-- automation lane the user drew, or the Effects Editor's own SysEx, and looks
-- exactly like a replacement that worked -- the new value is present either
-- way. So most of this file seeds unrelated events around the cursor and
-- proves they survive.
--
-- The real part_insert.lua runs against the harness take fake; nothing is
-- copied. Encoding comes from part_messages.lua, already pinned in phase 2,
-- so the expectations here are about placement and survival rather than bytes.
--   lua tests/test_part_insert.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local GS = require 'gs_sysex'
local PM = require 'part_messages'
local PI = require 'part_insert'
local check = H.check

-- An inserter wired to a fake take. `cursor` is the tick the edit cursor
-- reports, and `ppq_per_qn` the take's resolution.
local function rig(opts)
  opts = opts or {}
  local take = H.take(opts)
  local ins = PI.new({ reaper = H.reaper(take) })
  return ins, take
end

local function cc_str(take)
  return table.concat(take:cc_list(), ' | ')
end

-- run geometry --------------------------------------------------------------

-- The manual asks for roughly one tick at 96 PPQ between adjacent control
-- changes, so a sequencer cannot reorder them at the same instant. Scaling
-- from the take's own resolution keeps that musically identical elsewhere.
local GAPS = {
  { 96, 1 },     -- the reference resolution
  { 192, 2 },
  { 480, 5 },    -- the manual names this one explicitly
  { 960, 10 },   -- REAPER's default
  { 24, 1 },     -- below the reference, the gap must not round to 0
  { 1, 1 },
}
for _, c in ipairs(GAPS) do
  local ins, take = rig({ ppq_per_qn = c[1] })
  check(ins:gap(take) == c[2],
    ('gap at %d PPQ is %d, expected %d'):format(c[1], ins:gap(take), c[2]))
end

-- A take that cannot answer falls back to a sane resolution rather than a
-- zero gap, which would stack every message of a run on one tick.
do
  local take = H.take()
  local R = H.reaper(take)
  R.MIDI_GetPPQPosFromProjQN = function() error('no') end
  local ins = PI.new({ reaper = R })
  check(ins:gap(take) >= 1, 'an unreadable take must still give a positive gap')
end
H.pass('run spacing scales from the take resolution and never reaches 0 (7 cases)')

-- single-message insertion ----------------------------------------------------

-- A plain CC lands on the cursor tick, on the channel its Part selects, with
-- nothing selected or muted.
local ins1, take1 = rig({ cursor = 1000 })
check(ins1:insert(take1, 'level', 100, 1, false) == true, 'a plain CC must insert')
check(cc_str(take1) == '@1000 ch0 #7=100',
  'level must land at the cursor on channel 0, got ' .. cc_str(take1))
check(#take1.events == 0, 'a CC insert must write nothing into the sysex lane')
check(take1.sorted == 1, 'the take must be sorted exactly once, got ' .. take1.sorted)
check(#take1.undo == 1, 'one insert is one undo block, got ' .. #take1.undo)
check(take1.undo[1] == 'Insert Level', 'the undo point must name the parameter')

-- Part 16 is channel 15. The channel comes from the Part, not from anything
-- the caller passes separately.
local ins2, take2 = rig({ cursor = 500 })
ins2:insert(take2, 'level', 64, 16, false)
check(cc_str(take2) == '@500 ch15 #7=64',
  'part 16 must write on channel 15, got ' .. cc_str(take2))

-- A SysEx parameter lands in the text/sysex lane instead, as type -1.
local ins3, take3 = rig({ cursor = 200 })
ins3:insert(take3, 'level', 100, 1, true)
check(#take3.ccs == 0, 'a SysEx insert must write nothing into the CC lane')
check(#take3.events == 1, 'a SysEx insert must write one event')
check(take3.events[1].typ == -1, 'a hardware SysEx event is type -1')
check(take3.events[1].ppq == 200, 'it must land on the cursor tick')
local addr3 = GS.dt1_addr_of(take3.events[1].payload)
check(addr3 and addr3[2] == 0x11 and addr3[3] == 0x19,
  'it must carry the part 1 level address')
H.pass('single messages land on the cursor tick in the right lane (12 cases)')

-- run insertion ----------------------------------------------------------------

-- An RPN is written as an ordered run, spaced by the gap, in the documented
-- order. Same-tick reordering is exactly what the spacing exists to prevent.
local ins4, take4 = rig({ cursor = 1000, ppq_per_qn = 960 })
check(ins4:insert(take4, 'bend_range', 2, 1, false) == true, 'an RPN must insert')
check(#take4.ccs == 5, 'bend range is a five-message run, got ' .. #take4.ccs)
check(cc_str(take4) ==
  '@1000 ch0 #101=0 | @1010 ch0 #100=0 | @1020 ch0 #6=2 | ' ..
  '@1030 ch0 #101=127 | @1040 ch0 #100=127',
  'the run must be ordered and spaced, got ' .. cc_str(take4))
check(take4.sorted == 1, 'a run must still be one sort, got ' .. take4.sorted)
check(#take4.undo == 1, 'a run must still be one undo block, got ' .. #take4.undo)

-- No two messages of a run may share a tick, at any resolution.
for _, res in ipairs({ 96, 480, 960 }) do
  local ins, take = rig({ cursor = 0, ppq_per_qn = res })
  ins:insert(take, 'fine_tune', 0, 1, false)
  local seen = {}
  for _, c in ipairs(take.ccs) do
    check(not seen[c.ppq], ('two run messages share tick %d at %d PPQ')
      :format(c.ppq, res))
    seen[c.ppq] = true
  end
  check(#take.ccs == 6, 'fine tune is a six-message 14-bit run')
end
H.pass('a run is ordered, spaced and still one undo point (11 cases)')

-- replacement: the same parameter ------------------------------------------------

-- Re-inserting the same parameter at the same cursor replaces its previous
-- value rather than stacking an ambiguous second one.
local ins5, take5 = rig({ cursor = 1000 })
ins5:insert(take5, 'cutoff', 20, 1, false)
ins5:insert(take5, 'cutoff', -30, 1, false)
check(#take5.ccs == 1, 'the second insert must replace, not stack, got ' .. #take5.ccs)
check(cc_str(take5) == '@1000 ch0 #74=34',
  'only the newest value may remain, got ' .. cc_str(take5))

-- The same for SysEx, matched by its complete Part address.
local ins6, take6 = rig({ cursor = 1000 })
ins6:insert(take6, 'cutoff', 20, 1, true)
ins6:insert(take6, 'cutoff', -30, 1, true)
check(#take6.events == 1, 'a SysEx re-insert must replace, got ' .. #take6.events)

-- And for a run, which must be replaced whole rather than partly rewritten.
local ins7, take7 = rig({ cursor = 1000 })
ins7:insert(take7, 'bend_range', 2, 1, false)
ins7:insert(take7, 'bend_range', 12, 1, false)
check(#take7.ccs == 5, 'a run must be replaced whole, got ' .. #take7.ccs)
check(take7.ccs[3].msg3 == 12, 'the newest Data Entry value must be what remains')
H.pass('re-inserting one parameter replaces its previous representation (6 cases)')

-- replacement: across encodings ---------------------------------------------------

-- `Use SysEx?` changes the shape of a parameter's representation, not its
-- identity. Replacement checks both forms, or the take would carry two values
-- for one control and the later one would not reliably win.
local ins8, take8 = rig({ cursor = 1000 })
ins8:insert(take8, 'cutoff', 20, 1, false)      -- as a CC
ins8:insert(take8, 'cutoff', -30, 1, true)      -- now as SysEx
check(#take8.ccs == 0, 'the old CC form must be removed, got ' .. #take8.ccs)
check(#take8.events == 1, 'the new SysEx form must be present')

local ins9, take9 = rig({ cursor = 1000 })
ins9:insert(take9, 'cutoff', 20, 1, true)       -- as SysEx
ins9:insert(take9, 'cutoff', -30, 1, false)     -- now as a CC
check(#take9.events == 0, 'the old SysEx form must be removed, got ' .. #take9.events)
check(#take9.ccs == 1, 'the new CC form must be present')

-- Bend Range is the sharpest case: a five-message RPN run on one side and a
-- single DT1 write on the other.
local ins10, take10 = rig({ cursor = 1000 })
ins10:insert(take10, 'bend_range', 2, 1, false)
check(#take10.ccs == 5, 'the RPN run is present')
ins10:insert(take10, 'bend_range', 12, 1, true)
check(#take10.ccs == 0, 'the whole RPN run must be removed, got ' .. #take10.ccs)
check(#take10.events == 1, 'the DT1 form must be present')

ins10:insert(take10, 'bend_range', 7, 1, false)
check(#take10.events == 0, 'the DT1 form must be removed, got ' .. #take10.events)
check(#take10.ccs == 5, 'the RPN run must be back')
H.pass('replacement works across an encoding change, both ways (8 cases)')

-- targeted removal: what must survive -----------------------------------------------

-- The whole point of the phase. Everything seeded here sits at or around the
-- cursor and belongs to something else; inserting Cutoff must not touch any
-- of it.
local ins11, take11 = rig({ cursor = 1000 })

take11:add_cc(1000, 0, 74, 10)          -- the Part Editor's own previous cutoff
take11:add_cc(1000, 1, 74, 99)          -- SAME controller, DIFFERENT channel
take11:add_cc(1000, 0, 7, 100)          -- same channel, different controller
take11:add_cc(1000, 0, 11, 64)          -- an expression lane the user drew
take11:add_cc(2000, 0, 74, 50)          -- the same parameter, elsewhere in the take
take11:add_evt(1000, -1, GS.dt1({ 0x40, 0x11, 0x19, 100 }))  -- part 1 LEVEL sysex
take11:add_evt(1000, 1, 'a label')      -- the Effects Editor's readable label

ins11:insert(take11, 'cutoff', -30, 1, false)

check(#take11.ccs == 5,
  'exactly one CC may have been replaced, got ' .. #take11.ccs .. ': ' .. cc_str(take11))
local survived = cc_str(take11)
check(survived:find('ch1 #74=99', 1, true),
  'another channel\'s same controller must survive: ' .. survived)
check(survived:find('ch0 #7=100', 1, true),
  'another controller on the same channel must survive: ' .. survived)
check(survived:find('ch0 #11=64', 1, true),
  'an unrelated automation lane must survive: ' .. survived)
check(survived:find('@2000 ch0 #74=50', 1, true),
  'the same parameter elsewhere in the take must survive: ' .. survived)
check(survived:find('@1000 ch0 #74=34', 1, true),
  'the new value must be present: ' .. survived)

check(#take11.events == 2, 'neither the label nor the unrelated SysEx may go')
local kinds = {}
for _, e in ipairs(take11.events) do kinds[#kinds + 1] = e.typ end
table.sort(kinds)
check(kinds[1] == -1 and kinds[2] == 1,
  'the unrelated SysEx and the label must both survive')
H.pass('removal matches channel, controller and tick together (8 cases)')

-- SysEx removal matches the COMPLETE address, not merely any SysEx on the
-- tick. Two Part parameters differ only in the third address byte, and the
-- Effects Editor shares the same 40 block.
local ins12, take12 = rig({ cursor = 1000 })
take12:add_evt(1000, -1, GS.dt1({ 0x40, 0x11, 0x19, 100 }))  -- part 1 level
take12:add_evt(1000, -1, GS.dt1({ 0x40, 0x12, 0x32, 84 }))   -- part 2 CUTOFF
take12:add_evt(1000, -1, GS.dt1({ 0x40, 0x11, 0x33, 84 }))   -- part 1 RESONANCE
take12:add_evt(1000, -1, GS.dt1({ 0x40, 0x11, 0x32, 84 }))   -- part 1 cutoff: ours
take12:add_evt(1000, -1, GS.master_volume(64))               -- not a DT1 write at all

ins12:insert(take12, 'cutoff', -30, 1, true)
check(#take12.events == 5,
  'exactly one SysEx may have been replaced, got ' .. #take12.events)

local addrs = {}
for _, e in ipairs(take12.events) do
  local a = GS.dt1_addr_of(e.payload)
  addrs[#addrs + 1] = a and ('%02X%02X%02X'):format(a[1], a[2], a[3]) or 'other'
end
local joined = table.concat(addrs, ',')
check(joined:find('401119', 1, true), 'part 1 level must survive: ' .. joined)
check(joined:find('401232', 1, true), 'part 2 cutoff must survive: ' .. joined)
check(joined:find('401133', 1, true), 'part 1 resonance must survive: ' .. joined)
check(joined:find('other', 1, true), 'a non-DT1 SysEx must survive: ' .. joined)
H.pass('SysEx removal matches the complete Part address (5 cases)')

-- An RPN's removal must not take a bare CC6 the user wrote for something
-- else on another channel, nor the Data Entry of a different channel's RPN.
local ins13, take13 = rig({ cursor = 1000, ppq_per_qn = 960 })
take13:add_cc(1000, 1, 101, 0)     -- another channel's RPN selector
take13:add_cc(1010, 1, 100, 0)
take13:add_cc(1020, 1, 6, 12)
ins13:insert(take13, 'bend_range', 2, 1, false)
check(#take13.ccs == 8, 'the other channel\'s RPN must survive, got ' .. #take13.ccs)
local ch1 = 0
for _, c in ipairs(take13.ccs) do if c.chan == 1 then ch1 = ch1 + 1 end end
check(ch1 == 3, 'all three of the other channel\'s messages must survive')
H.pass('an RPN replacement leaves other channels\' runs alone (2 cases)')

-- An RPN replacement covers its whole span, not only its first tick. The
-- removal walk searches base..base+(n-1)*gap, which is why a run written at
-- one resolution is still found at that resolution.
local ins14, take14 = rig({ cursor = 1000, ppq_per_qn = 960 })
ins14:insert(take14, 'fine_tune', 0, 1, false)
check(#take14.ccs == 6, 'the 14-bit run is six messages')
local last_tick = take14.ccs[6].ppq
check(last_tick == 1000 + 5 * 10, 'the run must span five gaps, got ' .. last_tick)
ins14:insert(take14, 'fine_tune', 50, 1, false)
check(#take14.ccs == 6, 'the whole span must be replaced, got ' .. #take14.ccs)
H.pass('replacement covers a run\'s whole calculated span (3 cases)')

-- failure paths --------------------------------------------------------------------

-- No take: nothing is written, nothing is opened, and the caller keeps its
-- pending snapshot.
local ins15 = PI.new({ reaper = H.reaper(H.take()) })
local ok15, err15 = ins15:insert(nil, 'level', 100, 1, false)
check(ok15 == false, 'a missing take must fail')
check(type(err15) == 'string' and err15 ~= '', 'the failure must be reportable')

-- An unknown parameter fails before anything is touched.
local ins16, take16 = rig()
local ok16 = ins16:insert(take16, 'nope', 0, 1, false)
check(ok16 == false, 'an unknown parameter must fail')
check(#take16.undo == 0, 'a rejected insert must not open an undo block')
check(take16.sorted == 0, 'a rejected insert must not sort')

-- An encoding error -- here an impossible Part -- is reported rather than
-- raised, and again nothing is written.
local ins17, take17 = rig()
local ok17 = ins17:insert(take17, 'level', 100, 99, false)
check(ok17 == false, 'an out-of-range part must fail')
check(#take17.ccs == 0, 'a failed encode must write nothing')
check(#take17.undo == 0, 'a failed encode must not open an undo block')

-- A REAPER call that throws mid-write still closes the undo block. Leaving it
-- open would silently absorb the user's next unrelated edit.
local take18 = H.take({ cursor = 1000 })
local R18 = H.reaper(take18)
R18.MIDI_InsertCC = function() error('boom') end
local ins18 = PI.new({ reaper = R18 })
local ok18, err18 = ins18:insert(take18, 'level', 100, 1, false)
check(ok18 == false, 'a throwing write must fail')
check(#take18.undo == 1, 'the undo block must still be closed, got ' .. #take18.undo)
check(type(err18) == 'string', 'the failure must be reportable')
H.pass('failures report, write nothing, and never leave an undo block open (11 cases)')

-- every parameter, both modes ----------------------------------------------------------

-- The sweep: every row inserts, replaces itself cleanly, and leaves the take
-- holding exactly one representation of itself.
local P = require 'part_params'
for _, p in ipairs(P.PARAMS) do
  for _, use_sysex in ipairs({ false, true }) do
    for _, part in ipairs({ 1, 10, 16 }) do
      local ins, take = rig({ cursor = 1000 })
      local okA = ins:insert(take, p.id, p.default, part, use_sysex)
      check(okA == true, p.id .. ': first insert must succeed')
      local n_cc, n_sx = #take.ccs, #take.events
      check(n_cc + n_sx > 0, p.id .. ': must write something')

      local okB = ins:insert(take, p.id, p.max, part, use_sysex)
      check(okB == true, p.id .. ': second insert must succeed')
      check(#take.ccs == n_cc and #take.events == n_sx,
        ('%s: re-insert changed the event count from %d/%d to %d/%d')
          :format(p.id, n_cc, n_sx, #take.ccs, #take.events))
      check(take.sorted == 2, p.id .. ': one sort per insert')
      check(#take.undo == 2, p.id .. ': one undo block per insert')
    end
  end
end
H.pass('every parameter inserts and replaces itself on every part, both modes')

-- Two DIFFERENT parameters at the same cursor coexist: replacement is per
-- parameter, and an editor that wrote one after the other must end with both.
local ins19, take19 = rig({ cursor = 1000 })
ins19:insert(take19, 'cutoff', 20, 1, false)
ins19:insert(take19, 'resonance', -20, 1, false)
ins19:insert(take19, 'level', 100, 1, false)
check(#take19.ccs == 3, 'three parameters must coexist, got ' .. cc_str(take19))
ins19:insert(take19, 'cutoff', 60, 1, false)
check(#take19.ccs == 3, 'replacing one must leave the other two, got ' .. cc_str(take19))
H.pass('different parameters at one cursor do not replace each other (2 cases)')

-- readable labels -------------------------------------------------------------

-- A SysEx payload is an opaque blob in REAPER's editor, so an insert writes a
-- text event beside it saying what it is. The Effects Editor has done this
-- since it was written; a Part insert that skipped it would leave the take
-- half-annotated.
local function labels(take)
  local out = {}
  for _, e in ipairs(take.events) do
    if e.typ == 1 then out[#out + 1] = e.payload end
  end
  return out
end

local ins20, take20 = rig({ cursor = 1000 })
ins20:insert(take20, 'eq', 1, 1, true, 'On')
local l20 = labels(take20)
check(#l20 == 1, 'an insert must write one label, got ' .. #l20)
check(l20[1] == 'Part 1 EQ On',
  'the label must name the Part, the parameter and the value, got ' .. l20[1])

-- The channel is in the label because one take can hold edits for all sixteen
-- Parts, and the SysEx bytes alone do not say which.
local ins21, take21 = rig({ cursor = 1000 })
ins21:insert(take21, 'cutoff', 20, 10, true, '+20')
check(labels(take21)[1] == 'Part 10 Cutoff +20',
  'got ' .. tostring(labels(take21)[1]))

-- A CC insert is labelled too: the CC lane is readable, but the label says
-- which Part parameter it represents rather than only a controller number.
local ins22, take22 = rig({ cursor = 1000 })
ins22:insert(take22, 'level', 100, 1, false, '100')
check(labels(take22)[1] == 'Part 1 Level 100', 'a CC insert must be labelled too')

-- A run gets ONE label for the whole run, not one per message: the run is a
-- single parameter change and six labels would say the same thing six times.
local ins23, take23 = rig({ cursor = 1000 })
ins23:insert(take23, 'fine_tune', 0, 1, false, '+0 cents')
check(#labels(take23) == 1, 'a run must be labelled once, got ' .. #labels(take23))
check(take23.events[1].ppq == 1000, 'the label sits on the first tick')

-- Re-inserting replaces the label rather than stacking a second one, and the
-- new value is what remains.
local ins24, take24 = rig({ cursor = 1000 })
ins24:insert(take24, 'cutoff', 20, 1, true, '+20')
ins24:insert(take24, 'cutoff', -30, 1, true, '-30')
local l24 = labels(take24)
check(#l24 == 1, 'a re-insert must replace the label, got ' .. #l24)
check(l24[1] == 'Part 1 Cutoff -30', 'the newest label must remain, got ' .. l24[1])

-- Across an encoding change too: the label belongs to the parameter, not to
-- the shape its value happens to take.
local ins25, take25 = rig({ cursor = 1000 })
ins25:insert(take25, 'bend_range', 2, 1, false, '+2 st')
ins25:insert(take25, 'bend_range', 12, 1, true, '+12 st')
check(#labels(take25) == 1, 'one label across an encoding change, got '
  .. #labels(take25))
check(labels(take25)[1] == 'Part 1 Bend Range +12 st', 'got '
  .. labels(take25)[1])

-- Label removal is as targeted as everything else. Another parameter's label,
-- another Part's label, and the Effects Editor's own labels all survive.
local ins26, take26 = rig({ cursor = 1000 })
take26:add_evt(1000, 1, 'Part 1 Level 100')     -- another parameter, same Part
take26:add_evt(1000, 1, 'Part 2 Cutoff +20')    -- same parameter, another Part
take26:add_evt(1000, 1, 'Reverb Macro')         -- the Effects Editor's
take26:add_evt(1000, 1, 'Part 1 Cutoff +20')    -- ours

ins26:insert(take26, 'cutoff', -30, 1, true, '-30')
local l26 = labels(take26)
check(#l26 == 4, 'exactly one label may be replaced, got ' .. #l26
  .. ': ' .. table.concat(l26, ' | '))
local joined26 = table.concat(l26, ' | ')
check(joined26:find('Part 1 Level 100', 1, true),
  'another parameter label must survive: ' .. joined26)
check(joined26:find('Part 2 Cutoff +20', 1, true),
  'another Part label must survive: ' .. joined26)
check(joined26:find('Reverb Macro', 1, true),
  'the Effects Editor label must survive: ' .. joined26)
check(joined26:find('Part 1 Cutoff -30', 1, true),
  'and ours must be the new value: ' .. joined26)

-- Omitting the displayed value writes no label at all, which is what the
-- event-layout tests above rely on.
local ins27, take27 = rig({ cursor = 1000 })
ins27:insert(take27, 'cutoff', 20, 1, true)
check(#labels(take27) == 0, 'no displayed value means no label')
H.pass('inserts are labelled, and labels replace as targetedly as events (16 cases)')
