-- Characterization: the editor state that later phases have to carry across a
-- close and reopen, and the close path itself.
--
-- Phase 4 added session_state.lua and converted the editor to start(on_close).
-- Restoration is only meaningful if the shape being saved is known: which
-- values are plain data (serializable), which are live handles (never), and
-- what the close path actually does. This file pins that inventory so a field
-- that quietly changes type shows up as a failure rather than as a restore
-- that silently drops a value.
--
-- Phase 1 wrote these groups against the pre-refactor file; the two that
-- described the old shape (a file-scope context, a loop that just stopped)
-- now describe what replaced them.
--   lua tests/test_editor_state.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local check = H.check
local src = H.source()

-- cfg is the settings block. Phase 3 renamed tick_gap to midi_tick_gap and
-- deleted mode; label_events survived untouched. The gap is accepted under
-- either name so this reads against the file as it is now and as it was, but
-- the name it carries is pinned below.
do
  local decl = src:match('\n(local cfg = {.-})\n')
  check(decl, 'the cfg declaration must be findable -- was it moved?')
  local cfg = assert(load(decl .. '\nreturn cfg', 'cfg', 't', {}))()

  local gap = cfg.midi_tick_gap or cfg.tick_gap
  check(type(gap) == 'number', 'the MIDI tick gap is a number')
  check(type(cfg.label_events) == 'boolean', 'label_events is a boolean')
  check(gap >= 1, 'a gap below 1 would collapse a run onto one tick')

  -- The rename is the point: midi_tick_gap cannot be confused with the fixed
  -- 20 ms hardware interval the way a bare "tick_gap" could.
  check(cfg.midi_tick_gap ~= nil,
    'the gap must be named midi_tick_gap -- it is PPQ spacing, not hardware timing')
  check(cfg.tick_gap == nil, 'the old tick_gap name must be gone')
  check(cfg.mode == nil, 'cfg.mode must be gone -- there is one fixed behaviour now')

  -- Every cfg field must be a plain scalar: cfg is serialized wholesale by
  -- session_state, and a function or table here would not survive the trip.
  for k, v in pairs(cfg) do
    local t = type(v)
    check(t == 'number' or t == 'boolean' or t == 'string',
      ('cfg.%s is a %s; session state can only carry scalars'):format(k, t))
  end

end

-- The tick gap is clamped to a range the hardware can follow. The clamp is
-- what stops a run collapsing onto one tick (where all but one message is
-- dropped); it must survive the rename to midi_tick_gap.
do
  local clamp = H.lift({ 'clamp' }, { math = math })
  check(clamp(0, 1, 96) == 1, 'a gap below the minimum clamps up to 1')
  check(clamp(500, 1, 96) == 96, 'a gap above the maximum clamps down to 96')
  check(clamp(2, 1, 96) == 2, 'a valid gap is left alone')
end

-- The per-tab selection state. These are the values a reopened editor is
-- expected to restore, so each one's type is pinned: efx_type is an index,
-- the two part tables are 16 booleans each, and the preset selection is keyed
-- by block name.
do
  local efx_type = src:match('\nlocal efx_type = (%d+)')
  check(efx_type, 'efx_type must be findable -- was it renamed?')
  check(tonumber(efx_type) >= 1, 'efx_type is a 1-based index into EFX_TYPES')

  -- The part tables are declared empty and filled with 16 booleans; a missing
  -- entry reads as nil, which the checkbox treats as false. Restoration has to
  -- preserve that -- 16 entries, booleans only.
  for _, name in ipairs({ 'efx_parts', 'eq_parts' }) do
    check(src:match('\nlocal ' .. name .. ' = {'),
      name .. ' must be findable -- was it renamed?')
  end
  check(src:match('\nlocal fx_preset_sel = {'),
    'fx_preset_sel must be findable -- was it renamed?')
end

-- What must never be serialized. The ReaImGui context and the font are live
-- handles; writing them into ExtState would either fail or restore a dead
-- reference. Phase 4 moved both out of file scope: the context is made per
-- visit inside start(), and the font belongs to theme.lua.
do
  check(src:match('ImGui%.CreateContext') and
        src:match('local function start%(on_close%)'),
    'the context must be created inside start(), not at file scope')
  check(not src:match('\nlocal ctx = ImGui%.CreateContext'),
    'a file-scope context would outlive its window and be drawn into when dead')
  check(not src:match('ImGui%.CreateFont'),
    'the editor must not make its own font -- theme.lua owns the shared one')
  check(src:match('Theme%.FONT_SIZE'),
    'the editor must take its font size from the shared theme')

  -- The status line is transient by design: the plan excludes it from restored
  -- state, and it already expires on a timer.
  check(src:match('\nlocal STATUS_SECS = (%d+)'),
    'the status expiry must be findable -- restored state must not carry status')

  -- capture_state is the whole serializable surface. Nothing it returns may be
  -- a handle, so the fields it names are checked against the inventory above.
  local cap = H.body('capture_state')
  for _, forbidden in ipairs({ 'ctx', 'font', 'hw', 'on_close_cb' }) do
    check(not cap:match('[%s={,]' .. forbidden .. '%s*='),
      'capture_state must not serialize ' .. forbidden .. ' -- it is a live handle')
  end
  check(cap:match('active_tab'), 'the active tab is restored state (plan item 8)')
end

-- Preset selections are compared by identity (`p == selected`) in the combos
-- and the wheel-step, so they cannot be restored as decoded copies -- a copy
-- matches nothing and the wheel silently steps from index 1. They are saved
-- by name and re-resolved against the tables the new visit built.
do
  local cap = H.body('capture_state')
  check(cap:match('sel%.name'),
    'preset selections must be captured by name, not by reference')

  local res = H.body('restore_state')
  check(res:match('p%.name == want'),
    'a restored preset name must be looked up in the live preset tables')
end

-- The close path. The loop re-defers only while the window is open and the
-- user has not asked to leave; every other case lands on finish(), which is
-- the single exit. Three routes reach it -- the window close button, the
-- "Back to PAGER" footer button, and a start-up failure -- and PAGER must be
-- reopened exactly once however many of them fire.
do
  check(src:match('if open and not want_close then%s*reaper%.defer%(loop%)'),
    'the loop must re-defer only while open and not asked to close')

  local close_branch = src:match('if open and not want_close then.-\nend')
  check(close_branch and close_branch:find('finish()', 1, true),
    'every non-continuing frame must land on finish()')

  local fin = src:match('\n(finish = function%(%).-\nend)\n')
  check(fin, 'finish must be findable -- it is the one exit')

  -- Guarded: a second call returns without reopening PAGER. Without this, the
  -- footer button followed by the window closing would launch two launchers.
  check(fin:match('if closed then return end'),
    'finish must be idempotent -- on_close may be reached by several routes')
  check(fin:match('closed = true'), 'the guard must latch before the callback runs')

  -- Order: state is captured while the tables are still live, the queue is
  -- dropped rather than flushed, and only then is the context released.
  --
  -- Released means the reference is dropped -- ReaImGui has no DestroyContext
  -- and collects unattached objects left unused -- so the check is for the
  -- assignment, not for a call that does not exist.
  local save_at = fin:find('session:save', 1, true)
  local cancel_at = fin:find('hw:cancel()', 1, true)
  local release_at = fin:find('ctx = nil', 1, true)
  check(save_at and cancel_at and release_at, 'finish saves, cancels and releases')
  check(save_at < cancel_at and cancel_at < release_at,
    'finish must save state, then cancel the queue, then release the context')
  -- ReaImGui has no DestroyContext; calling one would be a nil-index error at
  -- the worst possible moment. Comments may name it (finish explains why it is
  -- absent), so only a call is rejected.
  check(not fin:match('ImGui%.DestroyContext%s*%('),
    'ReaImGui has no DestroyContext -- releasing is dropping the reference')

  -- A frame can still be scheduled after the context is gone; drawing into it
  -- would take REAPER down rather than raise a Lua error.
  check(src:match('if not ctx then return end'),
    'the loop must not draw after the context has been released')

  -- Queued previews are never converted into MIDI events; they stop existing.
  check(not fin:match('hw:flush'), 'closing must cancel the queue, not flush it')

  local _, defers = src:gsub('reaper%.defer%(loop%)', '')
  check(defers == 2,
    'exactly two defer(loop) calls are expected (the kickoff in start() and ' ..
    'the re-defer), found ' .. defers .. ' -- a new exit path needs review')

  -- Begin is given a p_open, which is what makes the window's close button
  -- reachable at all. That button, the footer button and a tool switch all
  -- route through finish().
  check(src:match("ImGui%.Begin%(ctx, 'PAGER %- Effects Editor', true%)"),
    'Begin must pass p_open so the window close button is honoured')
  check(src:match("ImGui%.Button%(ctx, 'Back to PAGER'%)"),
    'the footer must offer an explicit return to PAGER (plan item 9)')
end

-- The tool entry point. PAGER requires this module and calls start(); run as a
-- bare action it still opens itself, so the file works both ways.
do
  check(src:match('local M = { start = start }'),
    'the module must expose start() for the launcher')
  check(src:match("if not rawget%(_G, 'PAGER_TOOL'%) then start%(nil%) end"),
    'run directly it must still open; required by PAGER it must not')

  -- Restoration is passive: start() may load and apply state, but must not
  -- put anything on the hardware queue before the user edits something.
  local body = H.body('start')
  check(body:match('restore_state'), 'start() restores the previous visit')
  for _, sender in ipairs({ 'preview_batch', 'preview_payload', 'live_echo',
                            'hw:queue', 'hw:replace' }) do
    check(not body:find(sender, 1, true),
      'start() must not send ' .. sender .. ' -- restoration is passive')
  end
  check(body:match('RESTORED_NOTICE'),
    'a restore must say so on the status line (plan item 14)')
end

-- A project-tab change is handled while the window stays open: the old
-- project's state is saved, pending output is dropped so it cannot play into
-- the new project's route, and the new values arrive passively.
do
  local body = H.body('check_project')
  check(body:match('session:save'), 'the old project keeps what it had')
  check(body:match('hw:cancel'),
    'pending output must not follow the user to a new project')
  check(body:match('restore_state'), 'the new values are loaded')
  check(body:match('RESTORED_NOTICE'), 'the swap says the values were not sent')

  local save_at = body:find('session:save', 1, true)
  local load_at = body:find('restore_state', 1, true)
  check(save_at < load_at, 'save the old project before loading the new one')
end

-- Status messages are set through one function, so the restore notice
-- ("Restored values; not sent to hardware.") has exactly one place to go.
do
  local env = { reaper = { time_precise = function() return 123 end } }
  -- set_status writes two upvalues declared above it; compile them together.
  local decl = src:match("\n(local status, status_time = '', 0)\n")
  check(decl, 'the status upvalues must be findable')
  local body = H.body('set_status')
  local set_status, read = assert(load(
    decl .. '\n' .. body .. '\nreturn set_status, function() return status, status_time end',
    'set_status', 't', env))()

  set_status('Inserted Reverb: Hall 1 at cursor.')
  local text, when = read()
  check(text == 'Inserted Reverb: Hall 1 at cursor.', 'the message is stored verbatim')
  check(when == 123, 'the message is stamped with the current time, for expiry')
end

H.pass('editor state: cfg shape, selection state, non-serializable handles, ' ..
       'preset identity, close path, entry point, project swap (9 groups)')
