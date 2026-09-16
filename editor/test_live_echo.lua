-- Check: a slider settles once, on release, and a double-click reset settles
-- on the default. This is the rule every parameter row depends on -- in live
-- mode it decides which frame reaches the hardware -- and it is frame timing,
-- which no amount of reading the code makes obvious.
--
-- slider_settled is loaded out of effects_editor.lua rather than copied, so
-- this cannot pass against a stale duplicate of the logic. Run with any Lua:
--   lua editor/test_live_echo.lua

local frame = {}

-- The four ImGui queries slider_settled makes. Everything else the editor
-- calls is absent, which is why the function is extracted below rather than
-- the file being executed.
local ImGui = {
  MouseButton_Left = 0,
  IsItemDeactivatedAfterEdit = function() return frame.deactivated or false end,
  IsItemHovered               = function() return frame.hovered or false end,
  IsMouseDoubleClicked        = function() return frame.double_click or false end,
  IsMouseDown                 = function() return frame.mouse_down or false end,
}

-- Lift the real slider_settled out of the editor source. Loading the whole
-- file would need REAPER, so take the one function and compile it against a
-- stub environment -- if its body changes, this test runs the change.
local function load_slider_settled()
  local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'editor'
  local path = dir .. '/effects_editor.lua'
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local src = f:read('a')
  f:close()

  local body = src:match('\n(local function slider_settled%(e%).-\nend)\n')
  assert(body, 'slider_settled not found in ' .. path ..
                ' -- was it renamed? this test must follow it')

  -- ImGui is all the function reaches for, so a small environment keeps it
  -- from quietly growing a dependency on editor state unnoticed.
  local chunk = assert(load(body .. '\nreturn slider_settled',
                            'slider_settled', 't', { ImGui = ImGui }))
  return chunk()
end

local slider_settled = load_slider_settled()

-- Drive one entry through a list of frames, returning it and the frames on
-- which it reported settled.
local function run(frames)
  local e = { name = 'Reverb Time', default = 64, value = 64 }
  local settled = {}
  for i, f in ipairs(frames) do
    frame = f
    if f.value then e.value = f.value end   -- the slider writing a drag
    if slider_settled(e) then
      settled[#settled + 1] = { at = i, value = e.value }
    end
  end
  return e, settled
end

local function dragging(n, from)
  local fs = {}
  for i = 1, n do fs[i] = { value = from + i } end
  return fs
end

-- A drag settles once, on the release frame, carrying the value it landed on.
local frames = dragging(3, 60)
frames[#frames + 1] = { deactivated = true }
local e, s = run(frames)
assert(#s == 1, 'a drag must settle exactly once, got ' .. #s)
assert(s[1].at == 4, 'must settle on the release frame, got ' .. s[1].at)
assert(s[1].value == 63, 'must carry the released value, got ' .. s[1].value)

-- Dragging without releasing settles on no frame at all. This is the guard
-- against sending every frame, which would flood the MIDI port.
local _, s2 = run(dragging(20, 60))
assert(#s2 == 0, 'an unreleased drag must never settle, got ' .. #s2)

-- Double-click reset: the click drags the value to 120 and holds the button.
-- The second click of a double-click deactivates the widget on its own, so
-- the deactivated flag is set while the button is still down -- that is the
-- frame the latch has to suppress, and the reason it cannot simply trust the
-- flag. Without that suppression 120 would go out, then 64 on release.
local e3, s3 = run({
  { value = 120, hovered = true, double_click = true, mouse_down = true,
    deactivated = true },
  { mouse_down = true, deactivated = true },
  { deactivated = true },
})
assert(#s3 == 1, 'a reset must settle once, got ' .. #s3)
assert(s3[1].at == 3, 'a reset must settle on release, got frame ' .. s3[1].at)
assert(s3[1].value == 64, 'a reset must carry the default, got ' .. s3[1].value)
assert(e3.value == 64, 'the value must stay at the default afterwards')
assert(not e3.resetting, 'the latch must clear on release')

-- Deactivating with no edit settles nothing: a click that moves nothing
-- stays off the wire.
local _, s4 = run({ { deactivated = false } })
assert(#s4 == 0, 'no edit means no settle')

print('ok: slider settles on release only (4 cases, against the real function)')
