-- Check: "Insert only changes" writes ONLY parameters the user edited, and
-- never expands into a complete run.
--
-- This is the rule the button exists for, and it was got wrong once: an
-- earlier Phase 3 draft fell back to writing the complete run whenever no
-- run was found at the cursor, so moving the edit cursor silently turned a
-- two-event update into a sixteen-event one. The count assertions below are
-- what make that regression impossible to reintroduce quietly.
--
-- Everything is lifted out of effects_editor.lua and run against the fake
-- event lane in tests/harness.lua, with the real Humanizer parameter data.
--   lua tests/test_insert_changes.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local GS = require 'gs_sysex'
local EFX_PARAMS = require 'efx_params'
local EFX_TYPES = require 'efx_types'
local check = H.check

local TYPE = 5 -- Humanizer: 8 parameters, small enough to count by hand
local GAP = 2

-- Build the editor world around one fake take, with the real insertion
-- functions lifted into it.
local function rig(cursor)
  local ps = EFX_PARAMS[TYPE]
  for _, e in ipairs(ps) do e.min, e.value = e.min or 0, e.default end

  local EFX_SUB = assert(load(H.table_body('EFX_SUB') .. '\nreturn EFX_SUB',
                              'EFX_SUB', 't', {}))()
  for _, e in ipairs(EFX_SUB) do e.value = e.default end

  local take = H.take({ cursor = cursor or 1000 })
  local env = {
    math = math, ipairs = ipairs, select = select, string = string,
    type = type, tonumber = tonumber,
    SYSEX = -1, LABEL = 1, dt1 = GS.dt1, is_dt1_at = GS.is_dt1_at,
    cfg = { midi_tick_gap = GAP, label_events = true },
    EFX_SUB = EFX_SUB, EFX_PARAMS = EFX_PARAMS, EFX_TYPES = EFX_TYPES,
    efx_type = TYPE, NO_TAKE = 'no take',
    get_take = function() return take end,
    reaper = H.reaper(take),
  }
  env.reaper.MIDI_GetPPQPosFromProjTime = function() return take.cursor end

  local fns = { H.lift({ 'tick_of', 'count_events', 'delete_at', 'delete_sysex_at',
                         'find_dt1', 'cursor_ppq', 'clamp', 'delete_label_at',
                         'put_label' }, env) }
  env.tick_of, env.count_events, env.delete_at = fns[1], fns[2], fns[3]
  env.delete_sysex_at, env.find_dt1, env.cursor_ppq = fns[4], fns[5], fns[6]
  env.clamp, env.delete_label_at, env.put_label = fns[7], fns[8], fns[9]

  -- put_at and relabel_run are forward-declared locals, so they are lifted
  -- by their own patterns rather than as `local function`.
  local put_at_body = H.source():match('\n(put_at = function%(take, ppq, addr, value%).-\nend)\n')
  assert(put_at_body, 'put_at not found -- was it renamed?')
  env.put_at = assert(load(put_at_body .. '\nreturn put_at', 'put_at', 't', env))()
  local rl = H.source():match('\n(relabel_run = function%(take, base, text%).-\nend)\n')
  assert(rl, 'relabel_run not found -- was it renamed?')
  env.relabel_run = assert(load(rl .. '\nreturn relabel_run', 'relabel', 't', env))()

  env.efx_preset_events = H.lift({ 'efx_preset_events' }, env)
  env.insert_efx_preset = H.lift({ 'insert_efx_preset' }, env)
  env.efx_run_base = H.lift({ 'efx_run_base' }, env)
  env.efx_changed_params = H.lift({ 'efx_changed_params' }, env)
  local insert_changes = H.lift({ 'insert_efx_preset_changes' }, env)

  -- the built-in Default preset, exactly as efx_presets_for builds it
  local p = { name = 'Default', vals = {}, sub = {} }
  for _, e in ipairs(ps) do p.vals[#p.vals + 1] = e.default end
  for _, e in ipairs(EFX_SUB) do p.sub[#p.sub + 1] = e.default end

  return {
    take = take, ps = ps, sub = EFX_SUB, preset = p,
    insert_preset = env.insert_efx_preset,
    insert_changes = insert_changes,
    run_base = env.efx_run_base,
  }
end

-- SysEx events only; labels live in the text lane and are counted separately.
local function sysex_count(take) return #take:run() end

-- A complete run is the type event plus every parameter and sub value.
local COMPLETE = 1 + #EFX_PARAMS[TYPE] + 8

-- Nothing edited: nothing to write, whatever the cursor is doing.
do
  local r = rig()
  local ok, msg = r.insert_changes(r.preset)
  check(ok, 'an unedited preset must not be an error')
  check(msg:find('No changed'), 'it must say there is nothing to insert, got ' .. msg)
  check(sysex_count(r.take) == 0, 'nothing edited must write nothing')
end

-- On an existing run: only the edited parameters are rewritten, each into its
-- own slot, and the event count does not move.
do
  local r = rig()
  r.insert_preset(r.preset)
  local before = sysex_count(r.take)
  check(before == COMPLETE,
    ('a complete run is %d events, got %d'):format(COMPLETE, before))

  r.ps[1].value = 99   -- Drive
  r.ps[8].value = 100  -- Level
  local ok, msg = r.insert_changes(r.preset)
  check(ok, 'the update must succeed: ' .. tostring(msg))
  check(sysex_count(r.take) == before,
    ('updating slots must not add events, %d -> %d'):format(before, sysex_count(r.take)))

  -- The two edited values must be on the wire, in their own slots.
  local run = r.take:run()
  local base = 1000
  local drive = run[1 + 1]            -- type event, then parameter 1
  local level = run[1 + 8]
  check(drive.ppq == base + 1 * GAP, 'Drive keeps slot 1')
  check(level.ppq == base + 8 * GAP, 'Level keeps slot 8')
  check(drive.payload:byte(8) == 99, 'Drive must carry its edited value')
  check(level.payload:byte(8) == 100, 'Level must carry its edited value')
end

-- The regression: with the cursor away from any run, only the edited
-- parameters are written. A complete run here would be writing fifteen
-- values the user never touched.
do
  local r = rig()
  r.insert_preset(r.preset)
  local before = sysex_count(r.take)

  r.take.cursor = 5000            -- nowhere near the run
  check(r.run_base(r.take, r.ps) == nil, 'this test needs a cursor off the run')

  r.ps[1].value = 99
  r.ps[8].value = 100
  local ok, msg = r.insert_changes(r.preset)
  check(ok, 'writing changes off-run must succeed: ' .. tostring(msg))

  local written = sysex_count(r.take) - before
  check(written == 2,
    ('only the 2 edited parameters may be written, got %d'):format(written))
  check(written ~= COMPLETE, 'it must never expand into a complete run')
  check(msg:find('no run to update'),
    'the status must say why it packed them at the cursor, got ' .. msg)

  -- Packed from the cursor, one gap apart, rather than left in their slots.
  local at_cursor = {}
  for _, e in ipairs(r.take:run()) do
    if e.ppq >= 5000 then at_cursor[#at_cursor + 1] = e end
  end
  check(#at_cursor == 2, 'both changed values land at the cursor')
  check(at_cursor[1].ppq == 5000 and at_cursor[2].ppq == 5000 + GAP,
    'they are packed consecutively from the cursor')
end

-- One edited parameter writes one event, not a run. The count is the whole
-- point of the button.
do
  local r = rig()
  r.insert_preset(r.preset)
  local before = sysex_count(r.take)
  r.ps[3].value = 2
  r.insert_changes(r.preset)
  check(sysex_count(r.take) == before,
    'one edit on an existing run rewrites one slot, adding nothing')
end

H.pass('insert only changes writes only edited parameters, never a complete run (5 groups)')
