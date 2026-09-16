-- Check: a slider settles once, on release, and a double-click reset settles
-- on the default. This is the rule every parameter row depends on -- it
-- decides which frame reaches the hardware -- and it is frame timing, which
-- no amount of reading the code makes obvious.
--
-- slider_settled outlives the refactor unchanged: Phase 3 removes the output
-- modes, but "send on release, never mid-drag" is exactly what keeps the new
-- hardware queue from being flooded by a drag. The settling cases below are
-- therefore the permanent half of this file.
--
-- The mode predicates at the bottom are the temporary half. They are pinned
-- while they exist so that removing them is a reviewed deletion rather than a
-- silent behaviour change, and the check is written to pass either way: once
-- previewing()/sending() are gone, it reports that instead of failing. See
-- tests/test_editor_state.lua, which pins cfg.mode's disappearance from the
-- other side.
--
-- Everything is loaded out of effects_editor.lua rather than copied, so this
-- cannot pass against a stale duplicate of the logic. Run with any Lua:
--   lua tests/test_live_echo.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local check = H.check

local frame = {}

-- The four ImGui queries slider_settled makes. Everything else the editor
-- calls is absent, which is why the function is lifted rather than the file
-- being executed.
local ImGui = {
  MouseButton_Left = 0,
  IsItemDeactivatedAfterEdit = function() return frame.deactivated or false end,
  IsItemHovered               = function() return frame.hovered or false end,
  IsMouseDoubleClicked        = function() return frame.double_click or false end,
  IsMouseDown                 = function() return frame.mouse_down or false end,
}

local slider_settled = H.lift({ 'slider_settled' }, { ImGui = ImGui })

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
local _, s = run(frames)
check(#s == 1, 'a drag must settle exactly once, got ' .. #s)
check(s[1].at == 4, 'must settle on the release frame, got ' .. s[1].at)
check(s[1].value == 63, 'must carry the released value, got ' .. s[1].value)

-- Dragging without releasing settles on no frame at all. This is the guard
-- against sending every frame, which would flood the MIDI output -- and the
-- reason the hardware queue never sees a drag.
local _, s2 = run(dragging(20, 60))
check(#s2 == 0, 'an unreleased drag must never settle, got ' .. #s2)

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
check(#s3 == 1, 'a reset must settle once, got ' .. #s3)
check(s3[1].at == 3, 'a reset must settle on release, got frame ' .. s3[1].at)
check(s3[1].value == 64, 'a reset must carry the default, got ' .. s3[1].value)
check(e3.value == 64, 'the value must stay at the default afterwards')
check(not e3.resetting, 'the latch must clear on release')

-- Deactivating with no edit settles nothing: a click that moves nothing
-- stays off the wire.
local _, s4 = run({ { deactivated = false } })
check(#s4 == 0, 'no edit means no settle')

H.pass('slider settles on release only (4 cases, against the real function)')

-- The mode predicates, while they exist. Both read cfg as an upvalue rather
-- than a parameter, so they are compiled with an environment whose only entry
-- is a cfg table this file keeps a handle on.
--
-- Phase 3 deletes both functions along with cfg.mode. When that lands, the
-- lift below finds nothing and this section reports the removal instead of
-- failing -- the behaviour it described is then asserted directly by the
-- call sites, not by a mode lookup.
local src = H.source()
local have_modes = src:match('\nlocal function previewing%(%)')
                   and src:match('\nlocal function sending%(%)')

if not have_modes then
  print('ok: previewing()/sending() are gone -- output modes removed as planned')
else
  local mode_cfg = { mode = 'item' }
  local previewing, sending = H.lift({ 'previewing', 'sending' }, { cfg = mode_cfg })

  local function with_mode(mode, fn)
    mode_cfg.mode = mode
    return fn()
  end

  -- item never previews or sends; hybrid previews but item-writes (sending()
  -- stays false, so begin_write and friends still write to the item); live
  -- does both. Hybrid is the behaviour Phase 3 keeps as the only one.
  check(with_mode('item', previewing) == false, 'item must not preview')
  check(with_mode('item', sending) == false, 'item must not send')
  check(with_mode('hybrid', previewing) == true, 'hybrid must preview')
  check(with_mode('hybrid', sending) == false,
    'hybrid must not send -- Insert/Apply still write to the item')
  check(with_mode('live', previewing) == true, 'live must preview')
  check(with_mode('live', sending) == true, 'live must send')

  H.pass('previewing()/sending() match item/hybrid/live (6 cases, against the real functions)')
end
