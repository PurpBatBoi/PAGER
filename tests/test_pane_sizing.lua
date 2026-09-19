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

-- Measured in REAPER at PAGER's own font and style, not invented: these are
-- the values a sizing probe printed from the live Insertion Effects tab.
-- Using the real numbers matters -- an earlier version of this test guessed
-- text_row as 18 when it is 24, and so agreed with a window that was 16px
-- short.
--
-- A bordered child insets by WindowPadding (8), not FramePadding (3), and
-- draws a 1px border. frame_h is one row's frame; row_h adds the spacing
-- that follows it, which is what GetFrameHeightWithSpacing returns.
local frame_h, spacing_y, text_row, pad_y, border, TAB_PAD = 24, 4, 24, 8, 1, 18
local row_h = frame_h + spacing_y

-- N rows are N frames and the N-1 gaps between them -- not N row_h, which
-- would count a trailing gap after the last row and push its bottom padding
-- out of the pane.
local function rows_h(n)
  return n * frame_h + (n - 1) * spacing_y
end

local function col_h_for(avail_h)
  local col_h = rows_h(EFX_FIT_ROWS) + pad_y * 2 + border * 2
  local room = avail_h - text_row - TAB_PAD
  if col_h > room then col_h = math.max(room, row_h * 3) end
  return col_h
end

-- A window with plenty of room gets the full ten rows.
check(col_h_for(600) == rows_h(EFX_FIT_ROWS) + pad_y * 2 + border * 2,
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

-- The window must actually be tall enough to show the ten rows it asks for.
--
-- Found in REAPER: GTR Multi 1 drew eight rows, not ten. Nothing above was
-- wrong -- EFX_FIT_ROWS was 10 and the clamp behaved -- but efx_window_h
-- under-counted the chrome it has to fit around the panes, so the room left
-- came up two rows short and the clamp dutifully cut them.
--
-- The two heights are written in different places and must agree; that is
-- exactly the kind of pair that drifts. So this reproduces both sides and
-- checks the window leaves the panes their full height, rather than trusting
-- either number on its own.
do
  -- efx_window_h, as the editor computes it. Note `above` counts only what
  -- is drawn BEFORE the panes; the heading row and the bottom inset are
  -- added as clamped_off, because tab_insertion's clamp subtracts them from
  -- the room it measures. Counting the heading in both is what left the
  -- panes one row short.
  local function window_h(em)
    local panes = rows_h(EFX_FIT_ROWS) + pad_y * 2 + border * 2
    local above = row_h * 2 + text_row * 2 + em * 0.5
    local clamped_off = text_row + TAB_PAD
    local footer = row_h + spacing_y      -- exactly the loop's reservation
    local outside = row_h + footer + TAB_PAD * 2
    return panes + above + clamped_off + outside
  end

  -- What the frame loop then leaves the tab body, working back from that
  -- window: the footer it reserves, the tab bar, and the tab inset.
  local em = 14
  local h = window_h(em)
  local body = h - (row_h + spacing_y)       -- footer reservation
                 - row_h                      -- the outer tab bar
                 - TAB_PAD * 2                -- tab inset, top and bottom
  -- and what tab_insertion draws above the panes inside that body.
  local avail = body - (row_h * 2 + text_row * 2 + em * 0.5)

  local got = col_h_for(avail)
  local want = rows_h(EFX_FIT_ROWS) + pad_y * 2 + border * 2
  check(got == want,
    ('the requested window must fit all %d rows; the panes got %d of %d px')
      :format(EFX_FIT_ROWS, got, want))

  -- Stated as rows, which is what the acceptance test in REAPER counts.
  -- Rows that fit in the content box, counting the gaps between them only.
  local content = got - pad_y * 2 - border * 2
  local rows_shown = math.floor((content + spacing_y) / row_h)
  check(rows_shown == EFX_FIT_ROWS,
    ('GTR Multi 1 must show %d complete rows, the window allows %d')
      :format(EFX_FIT_ROWS, rows_shown))
end

-- The chrome the window budgets for must match what the tab actually draws.
-- Pinned against the source so adding a row to either side without the other
-- fails here rather than in REAPER.
do
  local body = src:match('local function tab_insertion%(%)(.-)\nend\n')
    or H.source():match('local function tab_insertion%(%)(.-)\n\nlocal')
  check(body, 'could not find tab_insertion in the source')

  -- The three Text labels on their own line, above the panes: the tab's
  -- title row, the part-assignment label, and the pane headings row.
  check(body:find("ImGui.Text(ctx, 'EFX Type:')", 1, true),
    "tab_insertion draws 'EFX Type:' on its own line -- efx_window_h counts it")
  check(body:find("ImGui.Text(ctx, 'Parts using EFX:')", 1, true),
    "tab_insertion draws 'Parts using EFX:' on its own line")
  check(body:find("ImGui.Text(ctx, 'Parameters')", 1, true),
    'the pane headings sit above the children, outside them')

  -- and the height that has to account for them.
  --
  -- Only TWO of those three text rows are counted in `above`: the heading
  -- row is drawn after the point tab_insertion measures its room, and its
  -- clamp already subtracts a text row and TAB_PAD there. Counting the
  -- heading in both places charges it twice and leaves the panes exactly one
  -- heading short -- the 16px the REAPER probe measured. It is added back as
  -- clamped_off instead, so the window covers what the clamp will take.
  local above = src:match('local above = ([^\n]+)')
  check(above and above:find('text_row * 2', 1, true),
    'efx_window_h must budget two text rows above the panes, got ' ..
    tostring(above))
  check(src:find('local clamped_off = text_row + TAB_PAD', 1, true),
    'efx_window_h must add back what the pane clamp subtracts')
  check(src:find('efx_win_h = panes + above + clamped_off + outside', 1, true),
    'the window height must include clamped_off')

  -- The footer must be reserved exactly as the frame loop reserves it --
  -- GetFrameHeightWithSpacing + one ItemSpacing, not two.
  check(src:find('local footer = row + spacing_y\n', 1, true),
    'the footer must be reserved exactly as the frame loop reserves it')
end

-- The pane inset must be measured with the style var that actually applies.
--
-- The second half of the same bug: with the window height fixed the panes
-- still showed nine rows and clipped the tenth, because the inset was
-- budgeted as FramePadding. ChildFlags_Borders "show[s] an outer border and
-- enable[s] WindowPadding" (ReaImGui api/window.cpp), and WindowPadding is
-- the larger of the two at the default style -- so the pane came up about a
-- row short.
--
-- Pinned by name rather than by arithmetic: the numbers here are stand-ins,
-- but which style var is read is the thing that was wrong.
do
  check(not src:find('StyleVar_FramePadding))\n  local col_h', 1, true),
    'the pane inset must not be measured as FramePadding')
  -- Ten rows are ten frames and nine gaps. Sizing them as ten
  -- GetFrameHeightWithSpacing counts a trailing gap that ImGui places inside
  -- the content box, ahead of the bottom padding, so the last row ends up
  -- flush against the border with its padding pushed out of view. Both the
  -- pane and the window height must use the same N-1 form.
  for _, want in ipairs({
    '(EFX_FIT_ROWS - 1) * spacing_y',
    'EFX_FIT_ROWS * ImGui.GetFrameHeight(ctx)',
    'local pad_y = select(2, ImGui.GetStyleVar(ctx, ImGui.StyleVar_WindowPadding))',
    'local border = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ChildBorderSize)',
  }) do
    local _, n = src:gsub(want:gsub('[%-%(%)%.%[%]%*%+%?%$%^%%]', '%%%0'), '')
    check(n >= 2,
      'both the pane and the window height must inset by WindowPadding and ' ..
      'the border; found ' .. n .. ' of 2 for: ' .. want)
  end
end

H.pass('insertion panes keep a positive height at every window size, and the ' ..
       'requested window fits all ten rows (14 cases)')
