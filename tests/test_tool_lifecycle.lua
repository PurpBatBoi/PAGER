-- The launcher handoff contract, driven against a headless ImGui boundary.
--
-- test_editor_state.lua reads the editor's source and pins the shape of the
-- close path; this file actually runs it. The two catch different things: a
-- source check cannot tell whether start() survives a real frame, and a run
-- cannot tell whether a field quietly stopped being serializable.
--
-- What PAGER relies on, and what is checked here for both tools:
--   * requiring the module opens nothing -- PAGER decides when
--   * start(on_close) opens a window and draws with the shared font and theme
--   * closing calls on_close exactly once, however many routes fire
--   * closing releases the context and saves state non-persistently
--   * a second start() restores the first visit's values, passively
--   * nothing reaches the hardware during a restore
--   lua tests/test_tool_lifecycle.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path
local EDITOR = dir .. '/../editor/'

local H = require 'harness'
local check = H.check

-- A headless ImGui. Every widget reports "unchanged" so a frame draws the
-- whole UI without simulating input; the calls that matter to the lifecycle
-- (context, font, window, style) are counted.
local function fake_imgui(state)
  local ImGui = {}

  -- Widgets return changed=false plus the value they were given, which is the
  -- shape every caller in the editor unpacks.
  local function unchanged(_, _, value) return false, value end

  local passthrough = {
    SliderInt = unchanged, SliderDouble = unchanged, InputText = unchanged,
    Checkbox = unchanged, InputInt = unchanged, DragInt = unchanged,
    RadioButton = function() return false end,
    Button = function() return false end,
    Selectable = function() return false end,
    MenuItem = function() return false end,
    BeginPopupModal = function() return false end,
    BeginPopup = function() return false end,
    BeginTabItem = function(_, label)
      -- Only the first tab is "open", which is what a real tab bar does; the
      -- rest report closed so their bodies do not draw.
      state.tabs_seen[#state.tabs_seen + 1] = label
      return label == state.open_tab
    end,
    BeginCombo = function(_, id, preview)
      -- The insertion-effect type combo's label is the selected type's name,
      -- so capturing it shows what the user would actually see on screen.
      if id == '##efxtype' then state.efx_combo = preview end
      return false
    end,
    BeginTabBar = function() return true end,
    BeginChild = function() return true end,
    BeginTable = function() return false end,
    Begin = function(_, title)
      state.begins = (state.begins or 0) + 1
      state.title = title
      state.fonts_at_begin = state.pushed_fonts - state.popped_fonts
      state.styles_at_begin = state.pushed_colors - state.popped_colors
      return state.visible, state.open
    end,
  }
  for k, v in pairs(passthrough) do ImGui[k] = v end

  ImGui.CreateContext = function()
    state.contexts = state.contexts + 1
    return 'ctx-' .. state.contexts
  end
  ImGui.CreateFont = function()
    state.fonts_created = state.fonts_created + 1
    return 'font'
  end
  ImGui.Attach = function() state.fonts_attached = state.fonts_attached + 1 end
  ImGui.PushFont = function() state.pushed_fonts = state.pushed_fonts + 1 end
  ImGui.PopFont = function() state.popped_fonts = state.popped_fonts + 1 end
  ImGui.PushStyleColor = function() state.pushed_colors = state.pushed_colors + 1 end
  ImGui.PopStyleColor = function(_, n) state.popped_colors = state.popped_colors + n end
  ImGui.PushStyleVar = function() state.pushed_vars = state.pushed_vars + 1 end
  ImGui.PopStyleVar = function(_, n) state.popped_vars = state.popped_vars + n end

  -- Measurements. Fixed numbers: the lifecycle does not depend on them, and a
  -- real font is not available here.
  ImGui.CalcTextSize = function(_, text) return #(text or '') * 7, 14 end
  ImGui.GetFrameHeight = function() return 21 end
  ImGui.GetFrameHeightWithSpacing = function() return 25 end
  ImGui.GetFontSize = function() return 14 end
  ImGui.GetContentRegionAvail = function() return 400, 300 end
  ImGui.GetCursorPos = function() return 0, 0 end
  ImGui.GetStyleVar = function() return 4, 4 end
  ImGui.GetMouseWheel = function() return 0, 0 end
  ImGui.GetScrollY = function() return 0 end
  ImGui.GetScrollMaxY = function() return 0 end
  ImGui.GetCursorScreenPos = function() return 0, 0 end
  ImGui.GetWindowDrawList = function() return 'drawlist' end
  ImGui.IsItemDeactivatedAfterEdit = function() return false end
  ImGui.IsItemHovered = function() return false end
  ImGui.IsWindowHovered = function() return false end
  ImGui.IsItemActive = function() return false end
  ImGui.IsKeyPressed = function() return false end

  -- Everything else -- End*, Text, SameLine, Separator, Dummy, the enum
  -- constants, the draw-list calls -- is a no-op that returns its own name,
  -- which is what makes the enum lookups (ImGui.Col_Text, ImGui.Cond_Always)
  -- resolve to something non-nil.
  --
  -- Except measurements: the layout code multiplies what Get*/…Height returns,
  -- and a string there fails with "attempt to mul a 'string'" rather than
  -- anything that points at the fake. Those return numbers.
  setmetatable(ImGui, {
    __index = function(_, key)
      local value
      if key:match('^Get') or key:match('Height') or key:match('Size') then
        value = function() return 14, 14 end
      else
        value = function() return key end
      end
      rawset(ImGui, key, value)
      return value
    end,
  })
  return ImGui
end

local function fake_reaper(state)
  return {
    ImGui_GetBuiltinPath = function() return '.' end,
    get_action_context = function() return false, EDITOR .. 'x.lua' end,
    defer = function(cb) state.deferred = cb end,
    time_precise = function() return state.now end,
    GetProjectPath = function() return 'C:/project' end,
    GetResourcePath = function() return dir .. '/../' end,
    ShowConsoleMsg = function(m) state.console = (state.console or '') .. m end,
    ShowMessageBox = function() return 0 end,
    EnumProjects = function() return state.project end,
    GetExtState = function(section, key)
      return state.ext[section .. '\0' .. key] or ''
    end,
    SetExtState = function(section, key, value, persist)
      state.ext[section .. '\0' .. key] = value
      state.persists[#state.persists + 1] = persist
    end,

    -- No MIDI take and no hardware route: this test is about the lifecycle,
    -- and every send path must be inert. Anything that did reach the hardware
    -- would show up in state.sent, which is asserted empty.
    MIDIEditor_GetActive = function() return nil end,
    MIDIEditor_GetTake = function() return nil end,
    GetSelectedMediaItem = function() return nil end,
    CountSelectedMediaItems = function() return 0 end,
    GetActiveTake = function() return nil end,
    TakeIsMIDI = function() return false end,
    GetMediaItemTake_Track = function() return nil end,
    GetMediaTrackInfo_Value = function() return -1 end,
    SendMIDIMessageToHardware = function(dev, msg)
      state.sent[#state.sent + 1] = { dev = dev, msg = msg }
    end,
    Undo_BeginBlock = function() end,
    Undo_EndBlock = function() end,
    MIDI_Sort = function() end,
  }
end

-- Run one tool through a full open/draw/close cycle. Returns the shared state
-- table so the caller can assert against what the run observed.
local function drive(file, opts)
  opts = opts or {}
  local state = {
    contexts = 0,
    fonts_created = 0, fonts_attached = 0,
    pushed_fonts = 0, popped_fonts = 0,
    pushed_colors = 0, popped_colors = 0,
    pushed_vars = 0, popped_vars = 0,
    tabs_seen = {}, sent = {}, persists = {},
    ext = opts.ext or {},
    project = opts.project or 'proj-A',
    visible = true, open = true,
    open_tab = opts.open_tab or 'Master',
    efx_combo = nil,
    now = 0,
    closes = 0,
  }

  local ImGui = fake_imgui(state)
  package.loaded.imgui = nil
  package.preload.imgui = function()
    return function(version)
      check(version == '0.10', 'the tool must ask for ReaImGui 0.10')
      return ImGui
    end
  end

  _G.reaper = fake_reaper(state)
  _G.PAGER_TOOL = true
  _G.MIDI_EXPORT_MIDIUTILS = {}

  -- Each run gets a fresh copy of every editor module: the editor keeps its
  -- values in file-scope tables, so a second require would hand back the
  -- first run's state and make a restore untestable.
  for name in pairs(package.loaded) do
    if name:match('^[a-z_]+$') and name ~= 'harness' then
      package.loaded[name] = nil
    end
  end

  local tool = assert(loadfile(EDITOR .. file))()
  check(type(tool) == 'table' and type(tool.start) == 'function',
    file .. ' must return a module exposing start(on_close)')
  check(state.deferred == nil,
    file .. ': requiring the module must not open a window')

  tool.start(function(...)
    state.closes = state.closes + 1
    state.close_args = { ... }
  end)
  check(state.deferred, file .. ': start() must schedule a frame')

  -- One frame with the window open, then one that reports it closed.
  state.deferred()
  if opts.frames then
    for _ = 2, opts.frames do if state.deferred then state.deferred() end end
  end

  -- keep_open lets a caller drive further frames itself -- a project switch
  -- happens while the window is still up, which is the whole point of it.
  if opts.keep_open then return state end

  state.open = false
  state.deferred()
  return state
end

-- The Effects Editor: open, draw, close, return once.
do
  local st = drive('effects_editor.lua')

  check(st.contexts == 1, 'one context per visit, got ' .. st.contexts)
  check(st.title == 'PAGER - Effects Editor',
    'the window keeps its name, got ' .. tostring(st.title))

  -- The shared font, from theme.lua, attached to this visit's context.
  check(st.fonts_created == 1 and st.fonts_attached == 1,
    'one shared font is created and attached, got ' ..
    st.fonts_created .. '/' .. st.fonts_attached)
  check(st.fonts_at_begin == 1, 'the font is active while the window draws')
  check(st.styles_at_begin > 0, 'the theme is active while the window draws')

  -- Balanced: an unpopped font or color leaks into whatever draws next, and
  -- in REAPER that is another script's window.
  check(st.pushed_fonts == st.popped_fonts,
    'the font stack is balanced across the frame')
  check(st.pushed_colors == st.popped_colors,
    'the color stack is balanced across the frame')
  check(st.pushed_vars == st.popped_vars,
    'the style-var stack is balanced across the frame')

  check(st.closes == 1, 'on_close fires exactly once, got ' .. st.closes)
  check(#st.sent == 0, 'a lifecycle with no user edit sends nothing')

  -- The context is released by dropping the reference (ReaImGui has no
  -- DestroyContext), so release is observed as the window no longer drawing.
  -- Two Begins: the open frame and the one that reported it closed.
  check(st.begins == 2, 'two frames drew before the close, got ' .. st.begins)

  -- State is saved for the next visit, and never for the next REAPER.
  check(#st.persists > 0, 'closing saves state')
  for _, persist in ipairs(st.persists) do
    check(persist == false, 'state is written with persist=false')
  end
end

-- Closing twice must not launch two PAGERs. The guard is what makes the
-- footer button and the window close button safe to both fire.
do
  local st = drive('effects_editor.lua')
  local drew = st.begins
  st.deferred()
  check(st.closes == 1,
    'a frame after close must not call on_close again, got ' .. st.closes)

  -- And it must not draw either. The context reference is gone; a Begin here
  -- would be a call into a released context, which takes REAPER down rather
  -- than raising a Lua error.
  check(st.begins == drew,
    'a frame after close must not draw into the released context')
end

-- A second visit restores the first one's values, and restores them
-- passively: the notice is shown and nothing is queued for the hardware.
do
  local shared = {}
  local first = drive('effects_editor.lua', { ext = shared })
  check(next(shared) ~= nil, 'the first visit left state behind')

  local second = drive('effects_editor.lua', { ext = shared })
  check(second.contexts == 1, 'the second visit makes its own context')
  check(#second.sent == 0,
    'restoring must send nothing -- it waits for the next user edit')
  check(second.closes == 1, 'the second visit also returns exactly once')
end

-- A different project tab starts clean rather than inheriting the first
-- project's values.
do
  local shared = {}
  drive('effects_editor.lua', { ext = shared, project = 'proj-A' })

  local keys = {}
  for key in pairs(shared) do keys[#keys + 1] = key end
  check(#keys == 1, 'one project wrote one record, got ' .. #keys)

  drive('effects_editor.lua', { ext = shared, project = 'proj-B' })
  local after = 0
  for _ in pairs(shared) do after = after + 1 end
  check(after == 2,
    'a second project must write its own record, got ' .. after .. ' total')
end

-- Switching REAPER project tabs with the window OPEN must swap the values on
-- screen, not merely say that it did.
--
-- This is a regression test. The first version of check_project let
-- session_state resolve the project itself, but by the time the switch is
-- noticed REAPER already reports the NEW project while the values still in the
-- editor belong to the OLD one. The save therefore wrote the old project's
-- values under the new project's key, and the load immediately read that same
-- record back: the status line said "Restored values" while nothing changed,
-- and the target project's saved state was destroyed on the way through.
do
  local json = require 'json'
  local SessionState = require 'session_state'
  local EFX_TYPES = require 'efx_types'

  -- Two projects holding clearly different insertion-effect types.
  local shared = {}
  local function seed(project, efx_type)
    shared[SessionState.SECTION .. '\0effects_editor:' .. project] =
      json.encode({ version = SessionState.VERSION,
                    state = { efx_type = efx_type,
                              active_tab = 'Insertion Effects' } })
  end
  seed('proj-A', 5)
  seed('proj-B', 30)

  local st = drive('effects_editor.lua', {
    ext = shared, project = 'proj-A',
    open_tab = 'Insertion Effects', keep_open = true,
  })
  check(st.efx_combo == EFX_TYPES[5][1],
    'the editor opens on its own project type, got ' .. tostring(st.efx_combo))

  -- The user switches project tabs. The window stays open; the next frame is
  -- where the tool notices.
  st.project = 'proj-B'
  st.deferred()
  check(st.efx_combo == EFX_TYPES[30][1],
    'switching projects must swap the values on screen, got ' ..
    tostring(st.efx_combo))
  check(#st.sent == 0, 'a project swap must send nothing to the hardware')

  -- And back again: the first project's values must still be there, which is
  -- what the overwriting save destroyed.
  st.project = 'proj-A'
  st.deferred()
  check(st.efx_combo == EFX_TYPES[5][1],
    'switching back must find the first project intact, got ' ..
    tostring(st.efx_combo))

  st.open = false
  st.deferred()
  check(st.closes == 1, 'the swap does not disturb the close path')
end

-- MIDI Export, through the same contract.
do
  local st = drive('midi-export.lua')
  check(st.title == 'PAGER - MIDI Export',
    'the exporter is renamed, got ' .. tostring(st.title))
  check(st.fonts_created == 1, 'the exporter uses the shared font')
  check(st.fonts_at_begin == 1, 'the font is active while the exporter draws')
  check(st.pushed_fonts == st.popped_fonts, 'the exporter balances the font stack')
  check(st.pushed_colors == st.popped_colors, 'the exporter balances the color stack')
  check(st.closes == 1, 'the exporter returns exactly once, got ' .. st.closes)

  -- Closed without exporting: PAGER is told there is no filename to show.
  check(st.close_args[1] == nil,
    'a cancelled export must report no result to the launcher')
end

H.pass('tool lifecycle: open, shared font and theme, balanced stacks, one ' ..
       'close, context release, passive restore, per-project state, live ' ..
       'project switch (6 groups)')
