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
    reaper = {
      Undo_BeginBlock = function() end,
      Undo_EndBlock = function() end,
      MIDI_Sort = function() end,
      MIDI_InsertTextSysexEvt = function(_, _, _, ppq, typ, payload)
        log.inserted[#log.inserted + 1] = { ppq = ppq, typ = typ, payload = payload }
      end,
    },
  }
  return H.lift({ 'insert_masters' }, env), log, masters
end

-- One event per master, one midi_tick_gap apart from the playhead, and
-- nothing sent: Insert writes, the preview already happened on edit.
do
  local insert_masters, log = harness(2)
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
  local insert_masters, log = harness(10)
  insert_masters()
  check(log.inserted[2].ppq == 1010,
        'midi_tick_gap ignored: second event at ' .. log.inserted[2].ppq)
end

-- Payloads come from each master's own build, in table order.
do
  local insert_masters, log = harness(2)
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
  local insert_masters, log = harness(2, true)
  local ok, msg = insert_masters()
  check(ok == false, 'a missing take must not report success')
  check(msg == 'no take', 'the caller must be told why, got ' .. tostring(msg))
  check(#log.inserted == 0, 'a missing take must write nothing')
  check(#log.sent == 0, 'nothing is ever sent from this path')
end

H.pass('master insert spacing, payloads, and the write-only Insert path (5 cases, against the real function)')
