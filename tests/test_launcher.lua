-- The PAGER launcher, driven against a headless ImGui.
--
-- test_tool_lifecycle.lua checks the other half of the same contract -- that
-- a tool opens, closes and calls back exactly once. This file checks what the
-- launcher does with that callback:
--
--   * five buttons in the fixed order, three of them disabled
--   * requiring the module does not open a window when under test
--   * clicking a tool closes the launcher BEFORE the tool starts
--   * only one window loop is alive at a time
--   * the tool's close callback opens a fresh launcher, exactly once
--   * a successful export shows "Exported: <filename>" with no popup
--   * a tool that cannot load, or throws in start(), still returns to PAGER
--
--   lua tests/test_launcher.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path
local EDITOR = dir .. '/../editor/'

local H = require 'harness'
local check = H.check

-- A headless ImGui, the same shape as the one in test_tool_lifecycle.lua but
-- only as wide as the launcher needs: it draws buttons, text and one window.
local function fake_imgui(state)
  local ImGui = {}

  ImGui.CreateContext = function()
    state.contexts = state.contexts + 1
    state.live_contexts = state.live_contexts + 1
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

  ImGui.Begin = function(_, title)
    state.begins = state.begins + 1
    state.title = title
    state.fonts_at_begin = state.pushed_fonts - state.popped_fonts
    state.styles_at_begin = state.pushed_colors - state.popped_colors
    return state.visible, state.open
  end

  -- Buttons are recorded in draw order, each tagged with whether it was
  -- disabled at the moment it was drawn. One click is delivered per run: the
  -- label in state.click, consumed so it cannot fire on a later frame.
  ImGui.BeginDisabled = function() state.disable_depth = state.disable_depth + 1 end
  ImGui.EndDisabled = function() state.disable_depth = state.disable_depth - 1 end
  ImGui.Button = function(_, label)
    state.buttons[#state.buttons + 1] =
      { label = label, disabled = state.disable_depth > 0 }
    if state.click == label then
      state.click = nil
      return true
    end
    return false
  end
  ImGui.Text = function(_, text) state.text[#state.text + 1] = text end

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
    -- Deliberately NOT pager.lua's own path. In a normal install the action
    -- and this file are the same, but under the .vscode debug launcher the
    -- action is that launcher and pager.lua is merely dofile()d -- so a
    -- SCRIPT_DIR taken from the action context would look for the tools in
    -- .vscode/. Pointing the fake somewhere else proves the tools are found
    -- beside pager.lua rather than beside the action.
    get_action_context = function()
      return false, EDITOR .. '../.vscode/debug_pager.lua'
    end,
    defer = function(cb) state.deferred = cb end,
    time_precise = function() return state.now end,
    MB = function() state.popups = state.popups + 1 return 0 end,
    ShowMessageBox = function() state.popups = state.popups + 1 return 0 end,
    ShowConsoleMsg = function(m) state.console = (state.console or '') .. m end,
    EnumProjects = function() return 'proj-A' end,
    GetExtState = function() return '' end,
    SetExtState = function() end,
  }
end

-- Load the launcher against the fakes and return it with its state table.
-- Each call gets a fresh copy: the launcher keeps ctx and status at file
-- scope, so a second require would hand back the previous run's window.
local function load_launcher(opts)
  opts = opts or {}
  local state = {
    contexts = 0, live_contexts = 0, begins = 0,
    fonts_created = 0, fonts_attached = 0,
    pushed_fonts = 0, popped_fonts = 0,
    pushed_colors = 0, popped_colors = 0,
    pushed_vars = 0, popped_vars = 0,
    buttons = {}, text = {}, disable_depth = 0,
    popups = 0, now = 0,
    tool_paths = {},
    visible = true, open = true,
    click = nil,
    started = {},          -- tools whose start() was called, in order
  }

  local ImGui = fake_imgui(state)
  package.loaded.imgui = nil
  package.preload.imgui = function()
    return function(version)
      check(version == '0.10', 'the launcher must ask for ReaImGui 0.10')
      return ImGui
    end
  end

  _G.reaper = fake_reaper(state)
  _G.PAGER_LAUNCHER_TEST = true

  for name in pairs(package.loaded) do
    if name:match('^[a-z_]+$') and name ~= 'harness' then
      package.loaded[name] = nil
    end
  end

  -- Stand-in tools. loadfile is intercepted so the launcher reaches these
  -- instead of the real editors: this test is about the handoff, and the
  -- tools' own lifecycles are already covered in test_tool_lifecycle.lua.
  local real_loadfile = loadfile
  _G.loadfile = function(path)
    local name = path:match('[^/\\]*$')
    local tool = opts.tools and opts.tools[name]
    if tool == nil then return real_loadfile(path) end
    -- Every tool must be looked for beside pager.lua. The action context the
    -- fake reports points at .vscode/ instead, so a launcher that resolved
    -- its directory from the action would land there and find nothing.
    state.tool_paths[#state.tool_paths + 1] = path
    check(path:gsub('\\', '/'):find('/editor/' .. name, 1, true),
      'tools are loaded from beside pager.lua, got ' .. path)
    if tool == false then return nil, 'no such file' end
    return function()
      return {
        start = function(on_close)
          state.started[#state.started + 1] = name
          -- The launcher must be gone before a tool is started. Asserted
          -- here, where the tool would be opening its own context.
          check(state.live_contexts == 0,
            'the launcher must release its context before a tool starts')
          state.on_close = on_close
          if tool.throw then error(tool.throw, 0) end
        end,
      }
    end
  end

  local launcher = assert(real_loadfile(EDITOR .. 'pager.lua'))()
  check(state.deferred == nil,
    'requiring the launcher must not open a window under test')
  state.restore_loadfile = function() _G.loadfile = real_loadfile end
  return launcher, state
end

-- Draw one frame. The launcher releases its context by dropping the
-- reference, which is not observable from Lua, so the fake tracks it instead:
-- a frame that reported the window closed is a frame after which no context
-- is live.
local function draw(state)
  local cb = state.deferred
  state.deferred = nil
  if cb then cb() end
end

-- Opening: one window, five buttons, the shared font and theme.
do
  local launcher, st = load_launcher()
  launcher.start(nil)
  check(st.deferred, 'start() must schedule a frame')
  draw(st)

  check(st.contexts == 1, 'one context per launcher, got ' .. st.contexts)
  check(st.title == 'PAGER', 'the window is named PAGER, got ' .. tostring(st.title))

  -- The row is checked against the launcher's own TOOLS table rather than a
  -- copy of the labels: the wording is the author's to change, and a test
  -- that hardcodes it fails on a rename that broke nothing. What must hold
  -- is the order, the count, and which entries are inert.
  check(#st.buttons == 5, 'five tool buttons, got ' .. #st.buttons)
  local order, want = {}, {}
  for i, b in ipairs(st.buttons) do order[i] = b.label end
  for i, t in ipairs(launcher.TOOLS) do want[i] = t.label end
  check(table.concat(order, ' ') == table.concat(want, ' '),
    'the buttons are drawn in TOOLS order, got ' .. table.concat(order, ' '))

  -- Part, Patch and Drum first, then the two that exist. The plan fixes this
  -- order: the unwritten tools are visible but lead the row.
  check(#launcher.TOOLS == 5, 'five tools, got ' .. #launcher.TOOLS)
  for i = 1, 3 do
    check(launcher.TOOLS[i].file == nil,
      ('tool %d (%s) is not written yet and must have no file')
        :format(i, launcher.TOOLS[i].label))
  end
  check(launcher.TOOLS[4].file == 'effects_editor.lua',
    'the fourth tool is the Effects Editor')
  check(launcher.TOOLS[5].file == 'midi-export.lua',
    'the fifth tool is MIDI Export')

  -- Disabled through BeginDisabled, not gray text: a drawn-gray button still
  -- takes the click. Exactly the three without a file.
  local disabled = {}
  for _, b in ipairs(st.buttons) do
    if b.disabled then disabled[#disabled + 1] = b.label end
  end
  check(#disabled == 3, 'three buttons are disabled, got ' .. #disabled)
  for i = 1, 3 do
    check(disabled[i] == launcher.TOOLS[i].label,
      ('the disabled buttons are the unwritten tools; expected %s, got %s')
        :format(launcher.TOOLS[i].label, tostring(disabled[i])))
  end
  check(st.disable_depth == 0, 'every BeginDisabled is matched by EndDisabled')

  -- The shared presentation, from theme.lua.
  check(st.fonts_created == 1 and st.fonts_attached == 1,
    'one shared font is created and attached')
  check(st.fonts_at_begin == 1, 'the font is active while the window draws')
  check(st.styles_at_begin > 0, 'the theme is active while the window draws')
  check(st.pushed_fonts == st.popped_fonts, 'the font stack is balanced')
  check(st.pushed_colors == st.popped_colors, 'the color stack is balanced')
  check(st.pushed_vars == st.popped_vars, 'the style-var stack is balanced')

  st.restore_loadfile()
end

-- Closing the launcher with no selection ends PAGER: no tool, no reopen.
do
  local launcher, st = load_launcher()
  launcher.start(nil)
  draw(st)
  st.open = false
  draw(st)

  check(#st.started == 0, 'closing the launcher starts no tool')
  check(st.contexts == 1, 'closing the launcher does not reopen it')
  check(st.deferred == nil, 'no further frames are scheduled after the close')
  st.restore_loadfile()
end

-- The full cycle: launcher -> tool -> launcher.
do
  local launcher, st = load_launcher({ tools = { ['effects_editor.lua'] = {} } })
  launcher.start(nil)
  draw(st)

  -- Click Effects. The click is recorded mid-frame and only sets a flag; the
  -- launcher still reaches End(), then closes at the tail of that same frame
  -- and starts the tool from its close path. So the tool starts after End()
  -- and after the context is released -- which is what live_contexts == 0
  -- inside the stand-in tool's start asserts -- rather than a frame later.
  st.click = launcher.TOOLS[4].label
  st.live_contexts = 0   -- the launcher drops its reference in finish()
  draw(st)
  check(#st.started == 1 and st.started[1] == 'effects_editor.lua',
    'clicking Effects starts the Effects Editor')
  check(st.begins == 2,
    'the clicked frame still completes its window, got ' .. st.begins)
  check(st.contexts == 1, 'the launcher is not still open behind the tool')

  -- The tool closes. A fresh launcher opens.
  local before_reopen = #st.buttons
  st.on_close(nil)
  check(st.contexts == 2, 'closing the tool opens a fresh launcher')
  check(st.deferred, 'the reopened launcher schedules a frame')
  draw(st)
  check(#st.buttons - before_reopen == 5,
    'the reopened launcher draws its five buttons again, got ' ..
    (#st.buttons - before_reopen))

  -- And exactly once, however many times a tool calls back.
  st.on_close(nil)
  check(st.contexts == 2,
    'a second on_close must not open a second launcher, got ' .. st.contexts)
  st.restore_loadfile()
end

-- A successful export reports its filename on the status line, not in a modal.
do
  local launcher, st = load_launcher({ tools = { ['midi-export.lua'] = {} } })
  launcher.start(nil)
  draw(st)
  st.click = launcher.TOOLS[5].label
  st.live_contexts = 0
  draw(st)
  check(#st.started == 1, 'clicking MIDI-Export starts the exporter')

  -- The shape midi-export.lua hands back after a successful export.
  st.on_close({ name = 'C:/songs/export-test.mid' })
  draw(st)

  local shown = table.concat(st.text, '|')
  check(shown:find('Exported: export%-test%.mid'),
    'the reopened launcher shows the exported filename, got ' .. shown)
  check(not shown:find('C:/songs'),
    'the status line shows the filename, not the whole path')
  check(st.popups == 0, 'a successful export opens no modal dialog')
  st.restore_loadfile()
end

-- A tool that will not load returns the user to PAGER with the reason.
do
  local launcher, st = load_launcher({ tools = { ['effects_editor.lua'] = false } })
  launcher.start(nil)
  draw(st)
  st.click = launcher.TOOLS[4].label
  st.live_contexts = 0
  draw(st)

  check(st.contexts == 2, 'a tool that cannot load still returns to PAGER')
  draw(st)
  local shown = table.concat(st.text, '|')
  check(shown:find('ERROR') and shown:find('Effects'),
    'the launcher reports which tool failed to load, got ' .. shown)
  st.restore_loadfile()
end

-- A tool that throws inside start() does the same: an error on the status
-- line of a live launcher beats no window at all.
do
  local launcher, st = load_launcher({
    tools = { ['effects_editor.lua'] = { throw = 'ReaImGui too old' } },
  })
  launcher.start(nil)
  draw(st)
  st.click = launcher.TOOLS[4].label
  st.live_contexts = 0
  draw(st)

  check(#st.started == 1, 'the tool was started')
  check(st.contexts == 2, 'a tool that throws in start() returns to PAGER')
  draw(st)
  local shown = table.concat(st.text, '|')
  check(shown:find('ReaImGui too old'),
    'the launcher shows the startup error, got ' .. shown)

  -- The failed tool's callback must not open yet another launcher.
  if st.on_close then st.on_close(nil) end
  check(st.contexts == 2,
    'a late callback from a failed tool opens no second launcher')
  st.restore_loadfile()
end

H.pass('launcher: five buttons in order with three disabled, shared font ' ..
       'and theme, balanced stacks, close without a tool, full ' ..
       'launcher/tool/launcher cycle, one reopen per close, non-modal ' ..
       'export confirmation, load failure and start failure both return ' ..
       'to PAGER (6 groups)')
