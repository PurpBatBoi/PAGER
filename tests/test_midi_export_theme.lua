-- Regression: the replacement MIDI exporter must use PAGER's shared theme and
-- shared font for every rendered frame, and must run as a tool that hands
-- control back exactly once.  This runs the real script bootstrap and the real
-- editor/theme.lua against a headless ImGui boundary, then checks the style
-- stack while the window is being drawn and after the frame is complete.
--
-- Phase 4 added three things this now covers: the font comes from theme.lua
-- (not a second CreateFont in the exporter), the window is titled
-- "PAGER - MIDI Export", and closing routes through one guarded exit.

local dir = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "tests"
local EDITOR = dir .. "/../editor/"

local scheduled
local console_error
local configured = false
local pushed_colors, pushed_vars = 0, 0
local colors_at_begin, vars_at_begin = 0, 0
local popped_colors, popped_vars = 0, 0
local fonts_created, fonts_attached = 0, 0
local pushed_fonts, popped_fonts = 0, 0
local fonts_at_begin = 0
local begin_title
local begins = 0
local closes = 0
-- Non-persistent ExtState, as session_state writes it.
local ext_store, ext_persist = {}, {}

local ImGui = {
  ConfigVar_ViewportsNoDecoration = 1,
  Cond_Always = 2,
  WindowFlags_AlwaysAutoResize = 4,

  CreateContext = function() return "midi-export-context" end,
  CreateFont = function() fonts_created = fonts_created + 1 return "font" end,
  Attach = function() fonts_attached = fonts_attached + 1 end,
  PushFont = function() pushed_fonts = pushed_fonts + 1 end,
  PopFont = function() popped_fonts = popped_fonts + 1 end,
  SetConfigVar = function(ctx, variable, value)
    assert(ctx == "midi-export-context")
    assert(variable == 1 and value == 0)
    configured = true
  end,
  PushStyleColor = function() pushed_colors = pushed_colors + 1 end,
  PushStyleVar = function() pushed_vars = pushed_vars + 1 end,
  PopStyleColor = function(_, count) popped_colors = count end,
  PopStyleVar = function(_, count) popped_vars = count end,
  SetNextWindowSize = function() end,
  Begin = function(_, title)
    begins = begins + 1
    begin_title = title
    colors_at_begin, vars_at_begin = pushed_colors, pushed_vars
    fonts_at_begin = pushed_fonts - popped_fonts
    return false, false
  end,
}

setmetatable(ImGui, {
  __index = function(_, key)
    if key:match("^Col_") or key:match("^StyleVar_") then return key end
  end,
})

package.preload.imgui = function()
  return function(version)
    assert(version == "0.10")
    return ImGui
  end
end

-- PAGER_TOOL suppresses the exporter's own auto-start, so the test drives
-- start() itself and can observe the close callback.
_G.PAGER_TOOL = true
_G.MIDI_EXPORT_TEST = nil
_G.MIDI_EXPORT_MIDIUTILS = {}
_G.reaper = {
  ImGui_GetBuiltinPath = function() return "." end,
  GetProjectPath = function() return "C:/project" end,
  get_action_context = function()
    return false, EDITOR .. "midi-export.lua"
  end,
  defer = function(callback) scheduled = callback end,
  ShowConsoleMsg = function(message) console_error = message end,
  time_precise = function() return 0 end,
  EnumProjects = function() return "proj-A" end,
  GetExtState = function(section, key)
    return ext_store[section .. "\0" .. key] or ""
  end,
  SetExtState = function(section, key, value, persist)
    ext_store[section .. "\0" .. key] = value
    ext_persist[#ext_persist + 1] = persist
  end,
}

local exporter = assert(loadfile(EDITOR .. "midi-export.lua"))()
assert(not console_error, console_error)
assert(type(exporter) == "table" and type(exporter.start) == "function",
  "the exporter must expose start(on_close) for the PAGER launcher")
assert(not scheduled,
  "requiring the exporter must not open a window -- PAGER decides when")

exporter.start(function() closes = closes + 1 end)
assert(scheduled, "MIDI exporter did not schedule its first ImGui frame")
scheduled()

assert(configured, "MIDI exporter did not configure themed viewport decorations")
assert(colors_at_begin > 0 and vars_at_begin > 0,
  "PAGER theme was not active while the MIDI export window rendered")
assert(popped_colors == pushed_colors and popped_vars == pushed_vars,
  "PAGER theme style stack was not balanced after the MIDI export frame")

-- The font is the shared one: created through theme.lua, attached to this
-- context, and pushed for the frame that draws the window.
assert(fonts_created == 1 and fonts_attached == 1,
  "exactly one shared font must be created and attached, got "
    .. fonts_created .. "/" .. fonts_attached)
assert(fonts_at_begin == 1,
  "the shared font must be active while the MIDI export window renders")
assert(pushed_fonts == popped_fonts,
  "the font stack was not balanced after the MIDI export frame")

assert(begin_title == "PAGER - MIDI Export",
  'the window must be titled "PAGER - MIDI Export", got ' .. tostring(begin_title))

-- Begin returned open=false, so that frame was the last one: the tool closes,
-- saves its settings non-persistently, releases its context, and returns to
-- PAGER exactly once.
assert(closes == 1, "on_close must be called exactly once, got " .. closes)
assert(#ext_persist > 0, "closing must save the export settings")
for _, persist in ipairs(ext_persist) do
  assert(persist == false,
    "session state must be written with persist=false -- it must not outlive REAPER")
end

-- A second frame must not reopen PAGER: the close guard has already latched.
-- It must not draw either -- the context reference is gone (ReaImGui has no
-- DestroyContext; an unused context is collected), and drawing into a released
-- context takes REAPER down rather than raising a Lua error.
local drew = begins
scheduled()
assert(closes == 1, "a second close must not call on_close again, got " .. closes)
assert(begins == drew, "a frame after close must not draw into the released context")

print("midi export theme lifecycle passed")
