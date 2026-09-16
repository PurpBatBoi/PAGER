-- Check: the Insertion Effects panes are never sized to a non-positive or
-- absurdly small height.
--
-- A tab change applies its new window height on the NEXT frame, so for one
-- frame the tab draws inside the previous tab's window. Settings is about
-- 170px and Insertion Effects about 420px, so switching Settings ->
-- Insertion Effects runs this math once against a window less than half the
-- height it wants. The room left over is then small, and can be negative.
--
-- BeginChild with a negative height does not mean "short" -- negative sizes
-- are measured back from the far edge -- so a clamp that can go negative
-- silently produces a child of the wrong size and destabilises the frame.
-- That surfaced as "ImGui_EndChild: Missing EndTabBar()", which names the
-- symptom rather than the cause, and closed the editor.
--
-- The sizing expression is lifted out of the real tab_insertion body so this
-- follows the code rather than a copy of it.
--   lua tests/test_pane_sizing.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local check = H.check

local src = H.source()

-- The clamp, as tab_insertion writes it. Pinned by pattern so that removing
-- the floor makes this test fail rather than quietly pass.
do
  check(src:find('if col_h > room then col_h = math.max(room, row_h * 3) end', 1, true),
    'the pane clamp must keep a floor -- a bare "col_h = room" can go negative')
end

-- Reproduce the expression against measured-style numbers and confirm the
-- result stays positive however little room is left.
local EFX_FIT_ROWS = tonumber(src:match('\nlocal EFX_FIT_ROWS = (%d+)'))
check(EFX_FIT_ROWS == 10, 'the viewport is ten rows, got ' .. tostring(EFX_FIT_ROWS))

local row_h, text_row, pad_y, TAB_PAD = 24, 18, 3, 18

local function col_h_for(avail_h)
  local col_h = EFX_FIT_ROWS * row_h + pad_y * 2
  local room = avail_h - text_row - TAB_PAD
  if col_h > room then col_h = math.max(room, row_h * 3) end
  return col_h
end

-- A window with plenty of room gets the full ten rows.
check(col_h_for(600) == EFX_FIT_ROWS * row_h + pad_y * 2,
  'with room to spare the panes get their full ten rows')

-- The cases that broke it: a short window, and one shorter than the chrome.
for _, avail in ipairs({ 300, 200, 120, 60, 30, 10, 0, -50 }) do
  local h = col_h_for(avail)
  check(h > 0, ('avail %d produced a pane height of %d'):format(avail, h))
  check(h >= row_h * 3,
    ('avail %d produced %d, below the three-row floor'):format(avail, h))
end

-- Switching Settings -> Insertion Effects is the concrete repro: one frame
-- inside the ~170px Settings window before the new height applies.
do
  local settings_like = 170 - row_h * 2 - TAB_PAD * 2  -- body room in that window
  local h = col_h_for(settings_like)
  check(h > 0, 'the Settings -> Insertion Effects frame must not go negative')
end

H.pass('insertion panes keep a positive height at every window size (11 cases)')
