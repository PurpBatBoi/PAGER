-- Characterization: how a run is laid out in the MIDI take, and how the
-- editor finds one that is already there.
--
-- This is the shape the refactor must preserve. Phase 3 removes the mode
-- branches and routes previews through a hardware queue, but what reaches the
-- take is not supposed to change at all: one event per tick, spaced by the
-- MIDI tick gap (midi_tick_gap), rewritten in place when a run already
-- sits at the cursor, with one label at the run base.
--
-- put_at, find_dt1, delete_at, delete_sysex_at, delete_label_at and put_label
-- are lifted out of effects_editor.lua and run against the fake event lane in
-- tests/harness.lua, so this follows the real functions rather than a copy.
--   lua tests/test_run_layout.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local GS = require 'gs_sysex'
local check = H.check

-- Everything the lifted lane helpers reach for. SYSEX/LABEL are the two event
-- types the editor writes; dt1 and is_dt1_at are the real GS encoders, so the
-- payloads here are byte-for-byte what REAPER would receive.
local function lane(take, cfg)
  local env = {
    -- type: put_at accepts a table of data bytes for the two-byte EFX type
    -- message as well as a single value.
    math = math, ipairs = ipairs, select = select, string = string, type = type,
    SYSEX = -1, LABEL = 1,
    dt1 = GS.dt1, is_dt1_at = GS.is_dt1_at,
    cfg = cfg or { midi_tick_gap = 2, label_events = true },
  }
  env.reaper = H.reaper(take)
  local fns = { H.lift({ 'tick_of', 'count_events', 'delete_at',
                         'delete_sysex_at', 'find_dt1', 'delete_label_at',
                         'put_label' }, env) }
  -- put_at is assigned to a forward-declared local (`put_at = function...`),
  -- so it is not a `local function` and is lifted by its own pattern.
  local put_at_body = H.source():match('\n(put_at = function%(take, ppq, addr, value%).-\nend)\n')
  assert(put_at_body, 'put_at not found -- was it renamed? this test must follow it')
  env.find_dt1, env.dt1 = fns[5], GS.dt1
  env.delete_sysex_at = fns[4]
  local put_at = assert(load(put_at_body .. '\nreturn put_at', 'put_at', 't', env))()
  return {
    tick_of = fns[1], count_events = fns[2], delete_at = fns[3],
    delete_sysex_at = fns[4], find_dt1 = fns[5], delete_label_at = fns[6],
    put_label = fns[7], put_at = put_at,
  }
end

local REV = 0x30 -- Reverb's addr_mid, as fx_blocks.lua defines it

-- A fresh run written one event per slot, exactly as insert_system_preset
-- and insert_efx_preset lay one out.
local function write_run(L, take, base, gap, addrs, values)
  for i, addr in ipairs(addrs) do
    L.put_at(take, base + (i - 1) * gap, addr, values[i])
  end
end

-- Case 1: a new run occupies consecutive ticks, one event each, never two on
-- the same tick. The hardware drops all but one SysEx at a single instant, so
-- a collapsed run is the failure that looks correct in the item.
do
  local take = H.take()
  local L = lane(take)
  local addrs = { { 0x40, REV, 0x00 }, { 0x40, REV, 0x01 }, { 0x40, REV, 0x02 } }
  write_run(L, take, 1000, 2, addrs, { 10, 20, 30 })

  local run = take:run()
  check(#run == 3, 'expected 3 events, got ' .. #run)
  H.check_spacing(take:ticks(), 1000, 2, 'new run')
  for i, e in ipairs(run) do
    check(GS.is_dt1_at(e.payload, addrs[i]),
      'event ' .. i .. ' must carry its own address')
    check(e.payload:byte(8) == ({ 10, 20, 30 })[i],
      'event ' .. i .. ' must carry its own value')
  end
end

-- Case 2: the gap is honoured rather than hard-coded. This is the setting the
-- refactor renamed to midi_tick_gap; the spacing behaviour survived it.
do
  local take = H.take()
  local L = lane(take, { midi_tick_gap = 10, label_events = true })
  write_run(L, take, 500, 10, { { 0x40, REV, 0x00 }, { 0x40, REV, 0x01 } }, { 1, 2 })
  H.check_spacing(take:ticks(), 500, 10, 'wide gap')
end

-- Case 3: rewriting a run in place updates the existing event rather than
-- replacing it. "Insert only changes" depends on this: it writes each changed
-- parameter back onto its own slot.
--
-- The count alone cannot prove this. put_at's fallback branch deletes the
-- tick and re-inserts, which lands on the same count as an update, so the
-- assertion is on the calls made: an in-place rewrite is one MIDI_SetTextSysexEvt
-- and no delete. Anything else means find_dt1 stopped matching and every
-- rewrite is silently destroying whatever else shares the tick.
do
  local take = H.take()
  local L = lane(take)
  local addrs = { { 0x40, REV, 0x00 }, { 0x40, REV, 0x01 } }
  write_run(L, take, 1000, 2, addrs, { 10, 20 })
  local before = take:count()

  local mark = #take.log
  L.put_at(take, 1002, addrs[2], 99) -- same address, same tick: an update

  local sets, deletes, inserts = 0, 0, 0
  for i = mark + 1, #take.log do
    local what = take.log[i][1]
    if what == 'set' then sets = sets + 1
    elseif what == 'delete' then deletes = deletes + 1
    elseif what == 'insert' then inserts = inserts + 1 end
  end
  check(sets == 1, 'an occupied slot must be updated in place, sets = ' .. sets)
  check(deletes == 0 and inserts == 0,
    ('an in-place rewrite must not delete/re-insert, got %d delete(s) and %d insert(s)')
      :format(deletes, inserts))

  check(take:count() == before,
    'rewriting a slot must not add an event, count went ' .. before ..
    ' -> ' .. take:count())
  local run = take:run()
  check(run[2].payload:byte(8) == 99, 'the slot must carry the new value')
  check(GS.is_dt1_at(run[2].payload, addrs[2]), 'the slot keeps its address')
end

-- Case 4: writing a different address onto an occupied tick replaces what was
-- there. Two SysEx events on one tick is the state that must never result.
do
  local take = H.take()
  local L = lane(take)
  L.put_at(take, 1000, { 0x40, REV, 0x00 }, 10)
  L.put_at(take, 1000, { 0x40, REV, 0x05 }, 20)

  local at = take:at(1000)
  local sysex = 0
  for _, e in ipairs(at) do if e.typ == -1 then sysex = sysex + 1 end end
  check(sysex == 1, 'a tick must hold one SysEx event, holds ' .. sysex)
  check(GS.is_dt1_at(take:run()[1].payload, { 0x40, REV, 0x05 }),
    'the later write must be the one that survives')
end

-- Case 5: find_dt1 locates a run by address within its span and reports the
-- tick it starts on -- this is what run_base and efx_run_base are built on,
-- and so what decides in-place update versus a fresh run at the cursor.
do
  local take = H.take()
  local L = lane(take)
  local addrs = { { 0x40, REV, 0x00 }, { 0x40, REV, 0x01 }, { 0x40, REV, 0x02 } }
  write_run(L, take, 1000, 2, addrs, { 10, 20, 30 })

  local idx, pos = L.find_dt1(take, 1000, addrs[3], 6)
  check(idx ~= nil, 'the third event must be found within the span')
  check(pos == 1004, 'it must report its own tick, got ' .. tostring(pos))

  -- Outside the span there is nothing to update, which is what makes an
  -- insert fall back to a fresh run at the cursor.
  check(L.find_dt1(take, 1000, addrs[3], 2) == nil,
    'a span that stops short must not match')
  check(L.find_dt1(take, 2000, addrs[1], 6) == nil,
    'a cursor past the run must not match')
  -- The device ID is deliberately not compared: an event written for another
  -- unit still occupies the tick.
  check(L.find_dt1(take, 1000, { 0x40, REV, 0x7A }, 6) == nil,
    'an address that is not in the run must not match')
end

-- Case 6: one label per run base, and re-labelling replaces rather than
-- stacks. relabel_run is delete_label_at followed by put_label.
do
  local take = H.take()
  local L = lane(take)
  L.put_at(take, 1000, { 0x40, REV, 0x00 }, 10)
  L.put_label(take, 1000, 'Reverb: Hall 1')
  L.delete_label_at(take, 1000)
  L.put_label(take, 1000, 'Reverb: Custom')

  local labels = take:labels()
  check(#labels == 1, 'a run base must carry exactly one label, got ' .. #labels)
  check(labels[1].text == 'Reverb: Custom', 'the newest label must win')
  check(labels[1].ppq == 1000, 'the label sits on the run base')
  check(#take:run() == 1, 're-labelling must not disturb the SysEx event')

  -- Rewriting the run base's value must leave that label alone. put_at's
  -- fallback branch clears the whole tick (label included) before inserting,
  -- so if in-place update ever stops matching, the run silently loses its
  -- name -- which is the visible symptom of the same break case 3 guards.
  L.put_at(take, 1000, { 0x40, REV, 0x00 }, 42)
  check(#take:labels() == 1,
    'an in-place rewrite must not remove the run label, got ' .. #take:labels())
  check(take:labels()[1].text == 'Reverb: Custom', 'and must not change it')
end

-- Case 7: label_events = false writes no label at all, and the run is
-- otherwise identical. The setting survives the refactor untouched.
do
  local take = H.take()
  local L = lane(take, { midi_tick_gap = 2, label_events = false })
  L.put_at(take, 1000, { 0x40, REV, 0x00 }, 10)
  L.put_label(take, 1000, 'Reverb: Hall 1')
  check(#take:labels() == 0, 'labels off must write no label')
  check(#take:run() == 1, 'labels off must not affect the run')
end

-- Case 8: delete_sysex_at clears both the event and its label from a tick and
-- reports how many SysEx events went -- the count insert_sysex uses to say
-- "Replaced" rather than "Inserted".
do
  local take = H.take()
  local L = lane(take)
  L.put_at(take, 1000, { 0x40, REV, 0x00 }, 10)
  L.put_label(take, 1000, 'Reverb: Hall 1')
  L.put_at(take, 1002, { 0x40, REV, 0x01 }, 20)

  local removed = L.delete_sysex_at(take, 1000)
  check(removed == 1, 'one SysEx event was removed, reported ' .. removed)
  check(#take:at(1000) == 0, 'the tick must be empty, label included')
  check(#take:run() == 1, 'the neighbouring tick must survive')
  check(L.delete_sysex_at(take, 900) == 0, 'an empty tick removes nothing')
end

H.pass('run layout: spacing, in-place rewrite, lookup, labels (8 cases, against the real functions)')
