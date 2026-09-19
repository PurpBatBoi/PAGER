-- Check: the Master Insert button writes one event per master, spaced by
-- midi_tick_gap, and sends nothing.
--
-- The four masters are independent parameters rather than a block run, so
-- nothing else in the file guards their layout. The thing that can silently
-- go wrong is collapsing them onto one tick -- the hardware drops all but one
-- of two SysEx messages at the same instant, so the item would look right and
-- sound wrong.
--
-- Phase 3 removed the output modes: Insert now always writes to the take and
-- never sends, because the values were already previewed as they were edited.
-- The send-path cases this file used to carry moved to
-- tests/test_hardware_output.lua, which owns hardware behaviour outright.
--
-- insert_masters is lifted out of effects_editor.lua rather than copied, so
-- a change to it runs here instead of a stale duplicate. Run with any Lua:
--   lua tests/test_insert_masters.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local check = H.check

-- Everything insert_masters reaches for, stubbed so the call is observable.
-- Kept deliberately minimal: a new dependency on editor state shows up as a
-- nil-index error here rather than passing quietly.
--
-- `sent` stays in the log even though nothing should ever land in it: an
-- Insert that starts sending again has to fail here, not pass silently.
-- no_take drives the one failure path Insert still has.
local function harness(gap, no_take)
  local log = { inserted = {}, sent = {}, labels = {}, deleted = {} }
  local masters = {
    { name = 'Level', value = 100, build = function(v) return 'L' .. v end },
    { name = 'Pan',   value = 3,   build = function(v) return 'P' .. v end },
    { name = 'Key',   value = -2,  build = function(v) return 'K' .. v end },
    { name = 'Tune',  value = 4400, build = function(v) return 'T' .. v end },
  }
  local env = {
    ipairs = ipairs, string = string,
    MASTERS = masters,
    SYSEX = -1,
    NO_TAKE = 'no take',
    cfg = { midi_tick_gap = gap },
    get_take = function() return not no_take and 'TAKE' or nil end,
    cursor_ppq = function() return 1000 end,
    delete_sysex_at = function(_, ppq) log.deleted[#log.deleted + 1] = ppq end,
    put_label = function(_, ppq, text) log.labels[#log.labels + 1] = { ppq, text } end,
    master_dirty = {},
    table = table,
    reaper = {
      Undo_BeginBlock = function() end,
      Undo_EndBlock = function() end,
      MIDI_Sort = function() end,
      MIDI_InsertTextSysexEvt = function(_, _, _, ppq, typ, payload)
        log.inserted[#log.inserted + 1] = { ppq = ppq, typ = typ, payload = payload }
      end,
    },
  }
  -- Both functions are lifted into ONE environment, so they share the
  -- master_dirty table exactly as they do in the editor -- a full insert
  -- clearing the marks is part of the contract under test.
  -- H.lift returns one value per name, in order.
  local insert_masters, insert_masters_changed =
    H.lift({ 'insert_masters', 'insert_masters_changed' }, env)
  return { insert_masters = insert_masters,
           insert_masters_changed = insert_masters_changed },
         log, masters, env
end

-- One event per master, one midi_tick_gap apart from the playhead, and
-- nothing sent: Insert writes, the preview already happened on edit.
do
  local fns, log = harness(2)
  local insert_masters = fns.insert_masters
  local ok, msg = insert_masters()
  check(ok, 'insert should succeed: ' .. tostring(msg))
  check(#log.inserted == 4, 'expected 4 events, got ' .. #log.inserted)
  check(#log.sent == 0, 'Insert must not send to hardware')

  local ticks = {}
  for i, e in ipairs(log.inserted) do
    check(e.typ == -1, 'events must be written as SysEx')
    ticks[i] = e.ppq
  end
  -- Spacing and the no-shared-tick rule are one shared assertion now.
  H.check_spacing(ticks, 1000, 2, 'masters')

  check(#log.labels == 1 and log.labels[1][1] == 1000,
        'exactly one label, at the run base')
end

-- The gap is honoured rather than hard-coded.
do
  local fns, log = harness(10)
  local insert_masters = fns.insert_masters
  insert_masters()
  check(log.inserted[2].ppq == 1010,
        'midi_tick_gap ignored: second event at ' .. log.inserted[2].ppq)
end

-- Payloads come from each master's own build, in table order.
do
  local fns, log = harness(2)
  local insert_masters = fns.insert_masters
  insert_masters()
  local want = { 'L100', 'P3', 'K-2', 'T4400' }
  for i, w in ipairs(want) do
    check(log.inserted[i].payload == w,
          ('event %d payload %q, expected %q'):format(i, log.inserted[i].payload, w))
  end
end

-- No take is the one failure Insert still has: nothing is written and the
-- caller is told why, rather than a run landing somewhere unexpected.
do
  local fns, log = harness(2, true)
  local insert_masters = fns.insert_masters
  local ok, msg = insert_masters()
  check(ok == false, 'a missing take must not report success')
  check(msg == 'no take', 'the caller must be told why, got ' .. tostring(msg))
  check(#log.inserted == 0, 'a missing take must write nothing')
  check(#log.sent == 0, 'nothing is ever sent from this path')
end

-- "Insert only changed": write the masters touched since the last insert,
-- and nothing else.
--
-- The point of the button is that the four masters are independent
-- addresses -- changing Pan should not rewrite Level, Key and Tune with
-- values the device already holds.
do
  local fns, log, _, env = harness(2)
  env.master_dirty.Pan = true
  env.master_dirty.Tune = true

  local ok, msg = fns.insert_masters_changed()
  check(ok, 'insert only changed should succeed: ' .. tostring(msg))
  check(#log.inserted == 2, 'expected 2 events, got ' .. #log.inserted)
  check(#log.sent == 0, 'Insert only changed must not send to hardware')

  -- MASTERS order, not touch order, so a run reads like a full insert.
  check(log.inserted[1].payload == 'P3', 'Pan first, got ' .. log.inserted[1].payload)
  check(log.inserted[2].payload == 'T4400', 'Tune second, got ' .. log.inserted[2].payload)

  -- Packed from the cursor: the skipped masters leave no gaps behind.
  H.check_spacing({ log.inserted[1].ppq, log.inserted[2].ppq }, 1000, 2,
                  'changed masters')

  -- The label names what was written, not 'Master settings'.
  check(#log.labels == 1, 'exactly one label')
  check(log.labels[1][2] == 'Master: Pan, Tune',
        'label must name the written masters, got ' .. log.labels[1][2])

  -- And the marks clear, so a second click has nothing to do.
  local ok2, msg2 = fns.insert_masters_changed()
  check(ok2 == false, 'a second insert with nothing changed must not succeed')
  check(#log.inserted == 2, 'a second insert must write nothing more')
  check(msg2:find('No master values changed', 1, true),
        'the caller is told nothing changed, got ' .. tostring(msg2))
end

-- One changed master: the singular message, and a one-event run.
do
  local fns, log, _, env = harness(2)
  env.master_dirty.Level = true
  local ok, msg = fns.insert_masters_changed()
  check(ok, 'one changed master should insert')
  check(#log.inserted == 1, 'expected 1 event, got ' .. #log.inserted)
  check(log.inserted[1].ppq == 1000, 'the single event sits at the cursor')
  check(msg:find('(1 event)', 1, true),
        'the message reads singular, got ' .. tostring(msg))
end

-- Nothing touched: the button writes nothing and says so. This is the state
-- the tab disables the button in, but the function must hold the line too --
-- a restored session has values without marks.
do
  local fns, log = harness(2)
  local ok, msg = fns.insert_masters_changed()
  check(ok == false, 'nothing changed must not report success')
  check(#log.inserted == 0, 'nothing changed must write nothing')
  check(#log.labels == 0, 'nothing changed must not label the lane')
  check(msg:find('No master values changed', 1, true),
        'the caller is told why, got ' .. tostring(msg))
end

-- A full Insert also clears the marks: having written every value, there is
-- nothing left that is "changed since the last insert".
do
  local fns, log, _, env = harness(2)
  env.master_dirty.Pan = true
  fns.insert_masters()
  check(#log.inserted == 4, 'the full insert writes all four')

  local ok = fns.insert_masters_changed()
  check(ok == false, 'a full insert must clear the changed marks')
  check(#log.inserted == 4, 'nothing more is written after a full insert')
end

-- No take fails the same way for both buttons, before anything is written.
do
  local fns, log, _, env = harness(2, true)
  env.master_dirty.Pan = true
  local ok, msg = fns.insert_masters_changed()
  check(ok == false, 'a missing take must not report success')
  check(msg == 'no take', 'the caller must be told why, got ' .. tostring(msg))
  check(#log.inserted == 0, 'a missing take must write nothing')
  -- The marks survive, so the edit is not lost to a mistimed click.
  check(env.master_dirty.Pan == true,
        'a failed insert must not clear the changed marks')
end

H.pass('master insert spacing, payloads, the write-only Insert path, and ' ..
       '"Insert only changed" selection, ordering, labelling, mark clearing ' ..
       'and failure paths (10 cases, against the real functions)')
