-- PAGER - the launcher.
--
-- The one action a user runs. It shows a row of five tools, hands control to
-- the one that is clicked, and gets control back when that tool closes.
--
-- The lifecycle is strictly sequential:
--
--     PAGER launcher -> selected tool -> PAGER launcher
--
-- and only one ReaImGui window loop is alive at any moment. That is the whole
-- reason this file exists rather than each tool being its own action: two
-- editors drawing at once would each own a context, a font and a hardware
-- queue, and a preview queued by one could play while the other is on screen.
--
-- So the launcher closes itself *before* starting a tool -- not after, and not
-- alongside. The tool is started from the close path, once this window has
-- stopped drawing and released its context.

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'PAGER', 0)
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path

-- The tools sit beside this file. get_action_context reports the path of the
-- running *action*, which is this file in a normal install, so that is the
-- first choice and the package works wherever it is installed.
--
-- It is not this file when something else loaded us: the .vscode debug
-- launcher is the registered action and dofile()s pager.lua, so the context
-- points at .vscode/ and every tool beside this file would be unreachable.
-- debug.getinfo names the file actually executing, which is right in both
-- cases; the action context is kept as the fallback for a host that strips
-- debug info.
local function script_dir()
  local source = debug.getinfo(1, 'S').source
  local path = source:match('^@(.*[/\\])')
  if path then return path end
  return ({ reaper.get_action_context() })[2]:match('^(.*[/\\])') or ''
end

local SCRIPT_DIR = script_dir()
package.path = SCRIPT_DIR .. '?.lua;' .. SCRIPT_DIR .. '../lib/?.lua;' .. package.path

-- Tell the tools they are being launched rather than run directly. Each one
-- ends with `if not rawget(_G, 'PAGER_TOOL') then start(nil) end`, so without
-- this flag requiring a tool would open its window immediately -- here, at
-- require time, behind the launcher.
_G.PAGER_TOOL = true

local ImGui = require 'imgui' '0.10'
local Theme = require 'theme'

local TITLE = 'PAGER'
local STATUS_SECS = 6

-- The five tools, in the fixed order the plan specifies:
--   [Part] [Patch] [Drum] [Effects] [MIDI-Export]
--
-- `file` is nil for a tool that does not exist yet. Those buttons are drawn
-- through BeginDisabled rather than as gray text, so ImGui also refuses the
-- click and the hover -- a fake-gray button still activates.
local TOOLS = {
  { label = 'Part' },
  { label = 'Patch' },
  { label = 'Drum' },
  { label = 'Effects',     file = 'effects_editor.lua' },
  { label = 'MIDI-Export', file = 'midi-export.lua' },
}

local ctx
local status, status_time = '', 0
local want_close = false   -- set by a click; the frame finishes, then we exit
local launch             -- the tool to start once this window is gone

local function set_status(message)
  status, status_time = message, reaper.time_precise()
end

-- Start a tool and arrange to come back here when it closes.
--
-- Two failure modes are handled, because leaving the user with no window at
-- all is the worst outcome available: a tool whose file will not load, and a
-- tool that throws while starting. Either way the error goes to the status
-- line of a fresh launcher rather than to a popup over nothing.
local function run_tool(tool, open_launcher)
  local chunk, load_err = loadfile(SCRIPT_DIR .. tool.file)
  if not chunk then
    return open_launcher('ERROR: ' .. tool.label .. ' could not be loaded: ' ..
                         tostring(load_err))
  end

  local loaded, module = pcall(chunk)
  if not loaded or type(module) ~= 'table' or type(module.start) ~= 'function' then
    return open_launcher('ERROR: ' .. tool.label .. ' is not a PAGER tool: ' ..
                         tostring(module))
  end

  -- Guarded on this side too. A tool promises to call back exactly once, but
  -- a second call would start a second launcher while the first is drawing --
  -- two windows, two contexts, the one thing this file exists to prevent.
  local returned = false
  local function on_close(result)
    if returned then return end
    returned = true

    -- MIDI Export hands back { name = <path> } after a successful export.
    -- That is the plan's non-modal confirmation: the launcher reopens with
    -- the filename on its status line instead of a modal dialog appearing
    -- over a window that is about to close anyway.
    local message = ''
    if type(result) == 'table' and result.name then
      message = 'Exported: ' .. tostring(result.name):match('[^/\\]*$')
    end
    open_launcher(message)
  end

  local started, start_err = pcall(module.start, on_close)
  if not started then
    -- The tool failed during start(), so its on_close will never fire and the
    -- guard above is still unset -- claim it, so a half-started tool that
    -- calls back later cannot open a second launcher on top of this one.
    if not returned then
      returned = true
      open_launcher('ERROR: ' .. tool.label .. ' failed to start: ' ..
                    tostring(start_err))
    end
  end
end

local frame, loop, finish, start

-- One horizontal row of buttons, then the status line under it.
frame = function()
  for index, tool in ipairs(TOOLS) do
    if index > 1 then ImGui.SameLine(ctx) end

    -- Not written yet: visible, so the user can see what is coming, but
    -- genuinely inert.
    local unavailable = tool.file == nil
    if unavailable then ImGui.BeginDisabled(ctx, true) end
    if ImGui.Button(ctx, tool.label) then
      -- Do not start the tool here. This is the middle of a frame that still
      -- has to reach End(); the launcher closes first and the tool starts
      -- from the close path.
      launch, want_close = tool, true
    end
    if unavailable then ImGui.EndDisabled(ctx) end
  end

  -- The status line keeps its own row whether or not there is a message, so
  -- an export confirmation does not make the window change height as it
  -- appears and then expires.
  ImGui.Spacing(ctx)
  if status ~= '' and reaper.time_precise() - status_time > STATUS_SECS then
    status = ''
  end
  ImGui.Text(ctx, status)
end

loop = function()
  -- A defer already scheduled when the window closed still runs once more.
  if not ctx then return end

  Theme.begin_frame(ctx, ImGui)
  -- AlwaysAutoResize: the window is exactly its button row plus its status
  -- line, and the row's width depends on the font, so no stored size is right
  -- on every machine.
  ImGui.SetNextWindowSize(ctx, 0, 0, ImGui.Cond_Always)
  local visible, open = ImGui.Begin(ctx, TITLE, true,
                                    ImGui.WindowFlags_AlwaysAutoResize)
  if visible then
    -- End() must run even if frame() throws, or ImGui is left mid-window and
    -- reports "Missing End()" over the top of the real error.
    local ok, err = pcall(frame)
    ImGui.End(ctx)
    if not ok then set_status('ERROR: ' .. tostring(err)) end
  end
  Theme.end_frame(ctx, ImGui)

  if open and not want_close then
    reaper.defer(loop)
  else
    finish()
  end
end

-- The single exit. Releases the context, then starts the pending tool if a
-- button asked for one; closing the window with no selection ends PAGER.
finish = function()
  -- Releasing the context is dropping the last reference to it: ReaImGui has
  -- no DestroyContext and collects unattached objects left unused. The font
  -- is attached to this context and goes with it (theme.lua keys its cache
  -- weakly, so the entry is collected rather than pinning a dead context).
  ctx = nil

  local tool = launch
  launch = nil
  if tool then
    -- Started only now, with this window gone: one loop at a time.
    run_tool(tool, function(message) start(message) end)
  end
end

-- Open a launcher. `message` is shown on the status line -- a returning tool
-- passes its result or its error, and the first run passes nothing.
start = function(message)
  want_close, launch = false, nil
  status, status_time = '', 0
  if message and message ~= '' then set_status(message) end

  ctx = ImGui.CreateContext(TITLE)
  -- native OS window frame instead of ImGui's drawn title bar, matching the
  -- tools.
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, 0)
  reaper.defer(loop)
end

-- Exposed for the lifecycle test, which drives start() against a headless
-- ImGui. As an action, PAGER simply opens.
local M = { start = start, TOOLS = TOOLS }

if not rawget(_G, 'PAGER_LAUNCHER_TEST') then start(nil) end

return M
