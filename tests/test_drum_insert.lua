-- Plan 001, step 3: writing one drum control into the take, and replacing
-- what was already there.
--
-- A focused file rather than more cases in test_part_insert.lua, because the
-- identity being tested is a different one. A Part insert is identified by
-- (Part, parameter) across two possible encodings; a drum insert is
-- identified by (map, note, parameter) in exactly one. Keeping the two apart
-- means neither file has to explain which rule it is asserting, and no
-- insertion case is maintained in both.
--
-- The dangerous half is the removal, not the insertion. A replacement that
-- matches too loosely deletes a neighbouring note's event, another map's
-- event, or the Effects Editor's own SysEx, and looks exactly like a
-- replacement that worked -- the new value is present either way. So most of
-- this file seeds unrelated events around the cursor and proves they survive.
--
-- The real part_insert.lua runs against the harness take fake; nothing is
-- copied. Encoding comes from drum_messages.lua, already pinned in step 1.
--   lua tests/test_drum_insert.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local GS = require 'gs_sysex'
local DM = require 'drum_messages'
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

local function hex(s)
  local out = {}
  for i = 1, #s do out[i] = ('%02X'):format(s:byte(i)) end
  return table.concat(out, ' ')
end

-- The SysEx payloads a take holds, in tick order.
local function sysex_payloads(take)
  local out = {}
  for _, e in ipairs(take:run()) do out[#out + 1] = hex(e.payload) end
  return out
end

-- The label texts a take holds, in tick order.
local function label_texts(take)
  local out = {}
  for _, e in ipairs(take:labels()) do out[#out + 1] = e.text end
  return out
end

-- The expected payload for one drum edit, built from the address helper
-- rather than from the inserter: what is under test here is placement and
-- survival, and the bytes themselves are already pinned byte for byte in
-- test_drum_messages.lua.
local function want_payload(mode, id, note, value)
  return hex(DM.encode(id, value, mode, note)[1].payload)
end

-- one insert, one event, one label ---------------------------------------------

do
  local ins, take = rig({ cursor = 1000 })
  local ok = ins:insert_drum(take, 1, 60, 'level', 100, '100')
  check(ok, 'a well-formed drum insert must succeed')

  local sx = sysex_payloads(take)
  check(#sx == 1, 'one drum edit is one SysEx event, got ' .. #sx)
  check(sx[1] == want_payload(1, 'level', 60, 100),
    'the exact encoded event must land, got ' .. sx[1])

  local labels = label_texts(take)
  check(#labels == 1, 'one readable label, got ' .. #labels)
  check(labels[1] == 'Drum 1 Note 60 Level 100',
    'the label must name map, note, parameter and value, got ' .. labels[1])

  -- Both sit on the cursor tick: the label shares its event's tick
  -- deliberately, so the item reads as one annotated change.
  check(take:run()[1].ppq == 1000, 'the event lands on the cursor')
  check(take:labels()[1].ppq == 1000, 'and its label shares that tick')

  -- One Insert is one undo point, and the take is sorted once, after both
  -- halves of the operation.
  check(#take.undo == 1, 'one undo block per insert, got ' .. #take.undo)
  check(take.sorted == 1, 'sorted exactly once, got ' .. take.sorted)
end
H.pass('a drum insert writes its exact event and one readable label (7 cases)')

-- the two maps are independent ---------------------------------------------------

-- DRUM 1 and DRUM 2 differ only in the high nibble of the middle address
-- byte. A removal matching on anything less than the complete address would
-- delete the other map's event and look like it worked.
do
  local ins, take = rig({ cursor = 1000 })
  ins:insert_drum(take, 1, 60, 'level', 100, '100')
  ins:insert_drum(take, 2, 60, 'level', 20, '20')

  local sx = sysex_payloads(take)
  check(#sx == 2, 'the two maps must both survive, got ' .. #sx)

  local found1, found2 = false, false
  for _, s in ipairs(sx) do
    if s == want_payload(1, 'level', 60, 100) then found1 = true end
    if s == want_payload(2, 'level', 60, 20) then found2 = true end
  end
  check(found1, 'the DRUM 1 event must survive')
  check(found2, 'the DRUM 2 event must survive')

  local labels = label_texts(take)
  check(#labels == 2, 'each map keeps its own label, got ' .. #labels)
  table.sort(labels)
  check(labels[1] == 'Drum 1 Note 60 Level 100'
        and labels[2] == 'Drum 2 Note 60 Level 20',
    'the labels must name their own map, got ' .. table.concat(labels, ' | '))
end
H.pass('DRUM 1 and DRUM 2 never replace each other (5 cases)')

-- notes and parameters are independent --------------------------------------------

do
  local ins, take = rig({ cursor = 1000 })
  ins:insert_drum(take, 1, 60, 'level', 100, '100')
  ins:insert_drum(take, 1, 61, 'level', 50, '50')
  check(#sysex_payloads(take) == 2,
    'two notes must not replace each other, got ' .. #sysex_payloads(take))

  ins:insert_drum(take, 1, 60, 'pan', 10, '10')
  check(#sysex_payloads(take) == 3,
    'two parameters must not replace each other, got ' .. #sysex_payloads(take))

  -- Every one of the three is still its own value.
  local want = {
    [want_payload(1, 'level', 60, 100)] = true,
    [want_payload(1, 'level', 61, 50)] = true,
    [want_payload(1, 'pan', 60, 10)] = true,
  }
  for _, s in ipairs(sysex_payloads(take)) do
    check(want[s], 'unexpected payload survived: ' .. s)
    want[s] = nil
  end
  check(next(want) == nil, 'every inserted event must still be present')

  check(#label_texts(take) == 3, 'and each keeps its own label')
end
H.pass('two notes and two parameters do not replace each other (6 cases)')

-- re-inserting replaces, and reuses the tick -----------------------------------------

do
  local ins, take = rig({ cursor = 1000 })
  ins:insert_drum(take, 1, 60, 'level', 100, '100')
  ins:insert_drum(take, 1, 60, 'level', 20, '20')

  local sx = sysex_payloads(take)
  check(#sx == 1, 'the same target must replace, not accumulate, got ' .. #sx)
  check(sx[1] == want_payload(1, 'level', 60, 20),
    'the newest value must be what remains, got ' .. sx[1])

  local labels = label_texts(take)
  check(#labels == 1, 'the old label must go with it, got ' .. #labels)
  check(labels[1] == 'Drum 1 Note 60 Level 20',
    'and the new label must show the new value, got ' .. labels[1])

  -- The replacement reuses the old event's tick rather than sliding past its
  -- own previous copy -- without that a re-edit marches further from the
  -- cursor every time.
  check(take:run()[1].ppq == 1000,
    'the replacement must reuse the cursor tick, got ' .. take:run()[1].ppq)

  -- Repeated re-inserts stay put and stay single.
  for i = 1, 5 do ins:insert_drum(take, 1, 60, 'level', i, tostring(i)) end
  check(#sysex_payloads(take) == 1, 'still one event after five re-inserts')
  check(take:run()[1].ppq == 1000, 'and still on the cursor tick')
  check(#label_texts(take) == 1, 'and still one label')
end
H.pass('re-inserting one target replaces it in place (8 cases)')

-- unrelated events at the same tick survive --------------------------------------

-- The whole point of matching on the complete address. Everything seeded
-- here sits on the cursor tick, which a tick-based removal would take with
-- it.
do
  local ins, take = rig({ cursor = 1000 })

  -- Another tool's SysEx: an Effects Editor write on the 40 block.
  local efx = GS.dt1({ 0x40, 0x01, 0x30, 0x02 })
  take:add_evt(1000, -1, efx)
  -- A drum event on a DIFFERENT parameter of the same note and map, written
  -- as though an earlier insert had put it there.
  local other = DM.encode('pan', 10, 1, 60)[1].payload
  take:add_evt(1000, -1, other)
  -- A foreign text label.
  take:add_evt(1000, 1, 'Part 10 Cutoff +20')
  -- A CC and a note, which a drum insert has no business touching.
  take:add_cc(1000, 9, 74, 64)

  ins:insert_drum(take, 1, 60, 'level', 100, '100')
  ins:insert_drum(take, 1, 60, 'level', 20, '20')  -- and replace it once

  local sx = sysex_payloads(take)
  local seen_efx, seen_other = false, false
  for _, s in ipairs(sx) do
    if s == hex(efx) then seen_efx = true end
    if s == hex(other) then seen_other = true end
  end
  check(seen_efx, 'the Effects Editor SysEx at the same tick must survive')
  check(seen_other, 'another drum parameter at the same tick must survive')

  local labels = label_texts(take)
  local seen_label = false
  for _, t in ipairs(labels) do
    if t == 'Part 10 Cutoff +20' then seen_label = true end
  end
  check(seen_label, 'a foreign label at the same tick must survive')

  check(#take.ccs == 1, 'the CC lane must be untouched, got ' .. #take.ccs)
  check(take.ccs[1].msg2 == 74, 'and must still be the CC that was there')

  -- Exactly one new drum Level event, alongside everything that was already
  -- there: three seeded SysEx events minus none, plus one.
  check(#sx == 3, 'one new event beside the two seeded ones, got ' .. #sx)
end
H.pass('unrelated SysEx, labels and CCs at one tick all survive (6 cases)')

-- collisions slide, and never stack ------------------------------------------------

-- Two SysEx messages on one tick leave their arrival order to the sort, so
-- the value that wins is not the one the user chose last. A new event must
-- slide off an occupied tick rather than share it.
do
  local ins, take = rig({ cursor = 1000, ppq_per_qn = 960 })
  -- Someone else's event is already on the cursor.
  take:add_evt(1000, -1, GS.dt1({ 0x40, 0x01, 0x30, 0x02 }))

  ins:insert_drum(take, 1, 60, 'level', 100, '100')

  local ticks = take:ticks()
  check(#ticks == 2, 'two events, two ticks, got ' .. #ticks)
  check(ticks[1] ~= ticks[2], 'they must not share a tick')
  -- 960 PPQ scales the manual's one-tick-at-96 gap to 10.
  check(ticks[2] == 1010,
    'the new event must slide one gap past the occupant, got ' .. ticks[2])

  -- Two drum inserts at one cursor also take their own ticks.
  local ins2, take2 = rig({ cursor = 1000, ppq_per_qn = 960 })
  ins2:insert_drum(take2, 1, 60, 'level', 100, '100')
  ins2:insert_drum(take2, 1, 61, 'level', 50, '50')
  local t2 = take2:ticks()
  check(#t2 == 2, 'two notes take two ticks, got ' .. #t2)
  check(t2[1] == 1000 and t2[2] == 1010,
    'the second must slide one gap, got ' .. table.concat(t2, ','))
end
H.pass('a collision slides the event instead of stacking (5 cases)')

-- failure paths --------------------------------------------------------------------

-- Every failure must leave the take as it found it, close its undo block, and
-- report rather than raise. The caller keeps its pending snapshot on a false
-- return, so a failure that looked like a success would silently lose an edit.
do
  -- No take.
  local ins = PI.new({ reaper = H.reaper(H.take()) })
  local ok, err = ins:insert_drum(nil, 1, 60, 'level', 100, '100')
  check(ok == false, 'a nil take must fail')
  check(type(err) == 'string' and #err > 0, 'and must say why')
end

do
  local BAD = {
    { 1, 60, 'nonesuch', 100, 'an unknown parameter' },
    { 0, 60, 'level', 100, 'map 0' },
    { 3, 60, 'level', 100, 'map 3' },
    { 1, -1, 'level', 100, 'note -1' },
    { 1, 128, 'level', 100, 'note 128' },
    { 1, 60.5, 'level', 100, 'a fractional note' },
    { 1, 60, 'level', 999, 'a value above the range' },
    { 1, 60, 'level', -1, 'a value below the range' },
    { 1, 60, 'level', 'x', 'a non-numeric value' },
  }
  for _, c in ipairs(BAD) do
    local ins, take = rig({ cursor = 1000 })
    local ok, err = ins:insert_drum(take, c[1], c[2], c[3], c[4], 'x')
    check(ok == false, c[5] .. ' must fail rather than insert')
    check(type(err) == 'string', c[5] .. ' must report a message')
    check(take:count() == 0,
      c[5] .. ' must write nothing, got ' .. take:count() .. ' events')
  end
end

-- An exception thrown mid-write still closes the undo block, or REAPER is
-- left with one open and the next unrelated edit joins it.
do
  local take = H.take({ cursor = 1000 })
  local R = H.reaper(take)
  R.MIDI_InsertTextSysexEvt = function() error('injected write failure', 0) end
  local ins = PI.new({ reaper = R })

  local ok, err = ins:insert_drum(take, 1, 60, 'level', 100, '100')
  check(ok == false, 'an injected write failure must be reported')
  check(tostring(err):find('injected', 1, true),
    'and must carry the underlying message, got ' .. tostring(err))
  check(#take.undo == 1, 'the undo block must still be closed, got ' .. #take.undo)

  -- Balanced: one begin, one end, and the end came last.
  local begins, ends = 0, 0
  for _, entry in ipairs(take.log) do
    if entry[1] == 'undo_begin' then begins = begins + 1 end
    if entry[1] == 'undo_end' then ends = ends + 1 end
  end
  check(begins == 1 and ends == 1,
    ('undo scope must balance, got %d begins and %d ends'):format(begins, ends))
  check(take.log[#take.log][1] == 'undo_end',
    'and the block must be the last thing closed')
end
H.pass('failures report, write nothing and keep undo balanced (34 cases)')

-- placement geometry --------------------------------------------------------------

-- The gap scales with the take's own resolution, exactly as a Part insert's
-- does; a drum insert is not a second placement policy.
do
  for _, c in ipairs({ { 96, 1 }, { 480, 5 }, { 960, 10 } }) do
    local ins, take = rig({ cursor = 0, ppq_per_qn = c[1] })
    take:add_evt(0, -1, GS.dt1({ 0x40, 0x01, 0x30, 0x02 }))
    ins:insert_drum(take, 1, 60, 'level', 100, '100')
    local ticks = take:ticks()
    check(ticks[2] == c[2],
      ('at %d PPQ the slide is %d, expected %d'):format(c[1], ticks[2], c[2]))
  end
end
H.pass('drum placement follows the take resolution (3 cases)')

H.pass('drum insertion: exact-address replacement, survival and failure')
