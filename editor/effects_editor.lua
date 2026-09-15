-- PAGER - Effects Editor
-- Inserts Roland GS SysEx events into the active MIDI take at the edit cursor,
-- or sends them straight to the hardware when live mode is on.
--
-- Laid out in sections, top to bottom: GS message building, the MIDI item and
-- its event lane, the status line, shared helpers, then one section per tab,
-- and finally the window and frame loop. Order matters here beyond taste --
-- Lua binds a local at closure creation, so a function must appear above its
-- callers or it resolves to a nil global and fails at run time, not at load.
--
-- The parameter tables live in sibling modules; see efx_params.lua,
-- efx_types.lua and fx_blocks.lua. baseline/ has a harness that records every
-- byte and status message this file produces, so a refactor can be checked.

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'PAGER - Effects Editor', 0)
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path

-- Data modules sit beside this file. get_action_context returns the path the
-- script was loaded from, so this works wherever the folder is installed.
local SCRIPT_DIR = ({ reaper.get_action_context() })[2]:match('^(.*[/\\])') or ''
package.path = SCRIPT_DIR .. '?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'
local GS = require 'gs_sysex'
local ctx = ImGui.CreateContext('PAGER - Effects Editor')

-- native OS window frame instead of ImGui's drawn title bar
ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, 0)

local FONT_SIZE = 16
local WIN_H = 334 -- default height; the width is measured by window_w
local TAB_PAD = 32 -- inset for tab contents
-- User settings, exposed on the Settings tab.
-- tick_gap: back-to-back events are too fast for the hardware to process.
-- label_events: write a readable text event alongside each insert.
-- live: send directly to the track's MIDI hardware output instead of the item.
local cfg = { tick_gap = 2, label_events = true, live = false }
local first_frame = true
local font = ImGui.CreateFont('sans-serif')
ImGui.Attach(ctx, font)

local dt1 = GS.dt1
local is_dt1_at = GS.is_dt1_at
local master_volume, master_tune = GS.master_volume, GS.master_tune
local hz_to_cents_x10 = GS.hz_to_cents_x10
local part_efx_addr = GS.part_efx_addr

-- Roland GS messages --------------------------------------------------------

-- Reset messages. GM1/GM2 are Universal Non-realtime (manual p.230): no
-- device ID and no checksum, so they do not go through dt1().
local RESETS = {
  { name = 'GS Reset', build = function() return dt1(GS.GS_RESET) end },
  { name = 'GM1 Reset',      build = function() return string.char(0x7E, 0x7F, 0x09, 0x01) end },
  { name = 'GM2 Reset',      build = function() return string.char(0x7E, 0x7F, 0x09, 0x03) end },
}
-- the MIDI item: finding, reading and editing the event lane ----------------

-- Active MIDI editor take, else the selected item's active take.
local function get_take()
  local take = reaper.MIDIEditor_GetTake(reaper.MIDIEditor_GetActive())
  if take and reaper.TakeIsMIDI(take) then return take end

  local item = reaper.GetSelectedMediaItem(0, 0)
  if item then
    take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then return take end
  end
end

-- The SC-8850 cannot receive two SysEx messages at the same instant, so an
-- insert replaces whatever is already on that tick rather than stacking.
-- PPQ is fractional: compare on the rounded tick, otherwise a cursor a hair
-- off never matches an existing event. Iterate backwards so deleting does
-- not shift the indices still to be visited.
-- Event types in the text/sysex lane: SysEx the hardware reads, and the
-- readable labels this script writes alongside it.
local SYSEX, LABEL = -1, 1

-- PPQ is fractional, so every tick comparison rounds. A cursor a hair off
-- would otherwise never match an event sitting on the same tick.
local function tick_of(ppq)
  return math.floor(ppq + 0.5)
end

local function count_events(take)
  return select(4, reaper.MIDI_CountEvts(take))
end

-- Delete events on one tick, keeping only those whose type `wanted` accepts.
-- Iterates backwards so deleting does not shift the indices still to visit.
-- Returns how many SysEx events went, which is how a caller tells a replace
-- from an insert.
local function delete_at(take, ppq, wanted)
  local tick, removed = tick_of(ppq), 0
  for i = count_events(take) - 1, 0, -1 do
    local ok, _, _, pos, typ = reaper.MIDI_GetTextSysexEvt(take, i, false, false, 0, 0, '')
    if ok and wanted(typ) and tick_of(pos) == tick then
      reaper.MIDI_DeleteTextSysexEvt(take, i)
      if typ == SYSEX then removed = removed + 1 end
    end
  end
  return removed
end

-- The label goes too, so re-inserting does not stack a second one on the tick.
local function delete_sysex_at(take, ppq)
  return delete_at(take, ppq, function(typ) return typ == SYSEX or typ == LABEL end)
end

-- Find an existing DT1 event whose address bytes match, searching from the
-- cursor tick forward over a short run. Returns index and ppq position, or
-- nil when there is no match - every caller checks the first return.
-- A DT1 payload is 41 <dev> 42 12 then three address bytes, so the address
-- starts at byte 5. The device ID is deliberately not compared: an event
-- written for another unit still occupies the tick.
local function find_dt1(take, from_ppq, addr, span)
  local first = tick_of(from_ppq)
  for i = 0, count_events(take) - 1 do
    local ok, _, _, pos, typ, msg = reaper.MIDI_GetTextSysexEvt(take, i, false, false, 0, 0, '')
    -- pos and msg are only meaningful once ok is true
    if ok and typ == SYSEX then
      local tick = tick_of(pos)
      if tick >= first and tick <= first + span and is_dt1_at(msg, addr) then
        return i, pos
      end
    end
  end
  return nil
end

local function delete_label_at(take, ppq)
  delete_at(take, ppq, function(typ) return typ == LABEL end)
end

-- Readable label in the text lane. Type 1 is a generic text event: visible in
-- the editor, ignored by the hardware.
local function put_label(take, ppq, text)
  if not cfg.label_events then return end
  reaper.MIDI_InsertTextSysexEvt(take, false, false, ppq, 1, text)
end

-- Direct send needs framing that REAPER supplies for item events.
local function send_live(payload, take)
  local track = reaper.GetMediaItemTake_Track(take)
  local hwout = reaper.GetMediaTrackInfo_Value(track, 'I_MIDIHWOUT')
  if hwout < 0 then
    return false, 'No MIDI hardware output on this track.'
  end
  local dev = hwout >> 5
  reaper.SendMIDIMessageToHardware(dev, string.char(0xF0) .. payload .. string.char(0xF7))
  return true
end

local NO_TAKE = 'No MIDI take: open a MIDI editor or select a MIDI item.'

-- Every write path starts the same way: there must be a take, and in live mode
-- the payload goes straight to the hardware instead of into the item. Returns
-- the take to write into, or nil plus the (ok, message) pair to return as-is.
local function begin_write(payload, name)
  local take = get_take()
  if not take then return nil, false, NO_TAKE end
  if cfg.live then
    local ok, err = send_live(payload, take)
    if not ok then return nil, false, err end
    return nil, true, 'Sent ' .. name .. ' to hardware.'
  end
  return take
end

local function cursor_ppq(take)
  return reaper.MIDI_GetPPQPosFromProjTime(take, reaper.GetCursorPosition())
end

local function insert_sysex(payload, name)
  local take, ok, msg = begin_write(payload, name)
  if not take then return ok, msg end

  local ppq = cursor_ppq(take)
  reaper.Undo_BeginBlock()
  local replaced = delete_sysex_at(take, ppq)
  reaper.MIDI_InsertTextSysexEvt(take, false, false, ppq, SYSEX, payload)
  put_label(take, ppq, name)
  reaper.MIDI_Sort(take)

  if replaced > 0 then
    reaper.Undo_EndBlock('Replace ' .. name, -1)
    return true, 'Replaced ' .. name .. ' at cursor.'
  end
  reaper.Undo_EndBlock('Insert ' .. name, -1)
  return true, 'Inserted ' .. name .. ' at cursor.'
end

-- status line ---------------------------------------------------------------

local status, status_time = '', 0
local STATUS_SECS = 4

local function set_status(msg)
  status, status_time = msg, reaper.time_precise()
end

-- shared helpers ------------------------------------------------------------

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

-- Draw text horizontally centred within `width` starting at the current cursor.
local function centred_text(text, width)
  local tw = ImGui.CalcTextSize(ctx, text)
  local x, y = ImGui.GetCursorPos(ctx)
  ImGui.SetCursorPos(ctx, x + math.max(0, (width - tw) / 2), y)
  ImGui.Text(ctx, text)
end

-- Master tab ----------------------------------------------------------------

-- Master controls: label, range, and how a value becomes a SysEx payload.
-- Pan and key shift are stored offset by 0x40, so 0 is centre / no transpose.
local MASTERS = {
  { name = 'Level', min = 0,    max = 127,  default = 127,
    build = function(v) return master_volume(v) end },
  { name = 'Pan',   min = -63,  max = 63,   default = 0,
    build = function(v) return dt1({ 0x40, 0x00, 0x06, v + 0x40 }) end },
  { name = 'Key-Shift', min = -24,  max = 24,   default = 0,
    build = function(v) return dt1({ 0x40, 0x00, 0x05, v + 0x40 }) end },
  { name = 'Tune',  min = 4153, max = 4662, default = 4400, hz = true,
    build = function(v) return master_tune(hz_to_cents_x10(v / 10.0)) end },
}

for _, m in ipairs(MASTERS) do m.value = m.default end

local function master_fader(m, em)
  local slider_w, input_w = em * 1.8, em * 3.4
  local label_w = ImGui.CalcTextSize(ctx, m.name)
  local col = math.max(slider_w, input_w, label_w)
  local x = ImGui.GetCursorPos(ctx)

  ImGui.BeginGroup(ctx)
  centred_text(m.name, col)

  -- Tune is held in tenths of a Hz so the slider can stay integer
  local fmt = m.hz and '%.1f' or '%d'
  local shown = m.hz and m.value / 10.0 or m.value

  ImGui.SetCursorPosX(ctx, x + (col - slider_w) / 2)
  local changed
  -- ClampOnInput: a value typed via Ctrl+Click is otherwise not clamped and
  -- can go out of bounds, which would not fit in a 7-bit MIDI data byte.
  changed, m.value = ImGui.VSliderInt(ctx, '##s' .. m.name, slider_w, em * 8,
                                      m.value, m.min, m.max,
                                      m.hz and '' or '%d',
                                      ImGui.SliderFlags_ClampOnInput)
  local send = ImGui.IsItemDeactivatedAfterEdit(ctx)

  -- Double-click resets to the default. The slider has already moved the value
  -- to the click position by this point, and the button stays down afterwards,
  -- so latch until release and keep forcing the default while it holds.
  if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
    m.resetting = true
  end
  if m.resetting then
    m.value = m.default
    send = false
    if not ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left) then m.resetting = false end
  end

  if m.hz then ImGui.SetItemTooltip(ctx, ('%.1f Hz'):format(shown)) end

  -- typed entry, since REAPER can intercept Ctrl+Click before ImGui sees it
  ImGui.SetCursorPosX(ctx, x + (col - input_w) / 2)
  ImGui.SetNextItemWidth(ctx, input_w)
  local entered, v
  if m.hz then
    entered, v = ImGui.InputDouble(ctx, '##i' .. m.name, shown, 0, 0, fmt)
    v = math.floor(v * 10 + 0.5)
  else
    entered, v = ImGui.InputInt(ctx, '##i' .. m.name, m.value, 0, 0)
  end
  if entered then
    -- neither InputInt nor InputDouble clamps
    m.value = clamp(v, m.min, m.max)
    send = true
  end
  ImGui.EndGroup(ctx)

  return send
end

local function tab_master()
  local em = ImGui.GetFontSize(ctx)
  for i, m in ipairs(MASTERS) do
    if i > 1 then ImGui.SameLine(ctx, 0, em * 1.2) end
    if master_fader(m, em) then
      local _, msg = insert_sysex(m.build(m.value), 'Master ' .. m.name)
      set_status(msg)
    end
  end

  -- to the right of the fader row, aligned with the tops of the sliders
  ImGui.SameLine(ctx, 0, em * 2)
  local _, y = ImGui.GetCursorPos(ctx)
  ImGui.SetCursorPosY(ctx, y + ImGui.GetTextLineHeightWithSpacing(ctx))
  ImGui.BeginGroup(ctx)
  for _, r in ipairs(RESETS) do
    if ImGui.Button(ctx, r.name) then
      local _, msg = insert_sysex(r.build(), r.name)
      set_status(msg)
    end
  end
  ImGui.EndGroup(ctx)
end

-- Insertion Effects tab -----------------------------------------------------

-- 65 insertion effect types, { name, MSB, LSB }; see efx_types.lua.
local EFX_TYPES = require 'efx_types'

local efx_type = 1 -- 1-based index into EFX_TYPES; entry 1 is 'Thru'

-- Label for an insertion event. A parameter name alone does not say much in
-- the event lane: 'Depth' could be any of a dozen effects, so the selected
-- type goes in too, matching the 'Reverb: Hall 1' form the system effects use.
local function efx_label(param)
  return ('EFX: %s | %s'):format(EFX_TYPES[efx_type][1], param)
end

-- Insertion Sub: the parameters common to every effect type, manual p.237.
-- Note the address skips 40 03 1A. Depth is stored 0-127 with 0x40 as 0%.
local EFX_SUB = {
  { name = 'Send Level To Reverb', addr = 0x17, min = 0, max = 127, default = 0x28 },
  { name = 'Send Level To Chorus', addr = 0x18, min = 0, max = 127, default = 0 },
  { name = 'Send Level To Delay',  addr = 0x19, min = 0, max = 127, default = 0 },
  { name = 'Control Source1',      addr = 0x1B, min = 0, max = 127, default = 0 },
  { name = 'Control Depth1',       addr = 0x1C, min = 0, max = 127, default = 0x40 },
  { name = 'Control Source2',      addr = 0x1D, min = 0, max = 127, default = 0 },
  { name = 'Control Depth2',       addr = 0x1E, min = 0, max = 127, default = 0x40 },
  { name = 'Send EQ Switch',       addr = 0x1F, min = 0, max = 1,   default = 1 },
}

local efx_parts = {}
local apply_efx_part
for i = 1, 16 do
  efx_parts[i] = false
end

for _, e in ipairs(EFX_SUB) do e.value = e.default end

-- Per-effect insertion parameters: 770 rows across 65 effect types, nearly
-- half the script by line count, so they live in a generated sibling module
-- rather than inline. See scripts/extract_efx.py for how it is built and
-- efx_params.lua for the field documentation.
local EFX_PARAMS = require 'efx_params'

-- Values are raw bytes, starting at the hardware's own default. The manual's
-- display range is kept as a hint beside the field rather than converted;
-- that needs the *1-*14 tables on manual p.224 and can be added per effect.
-- min is 0 throughout: no insertion parameter starts anywhere else, and the
-- signed-looking ones (Pan L63-0-R63, Feedback -98%-+98%) are stored offset,
-- so 0 is a real byte value rather than the displayed minimum.
for _, ps in pairs(EFX_PARAMS) do
  for _, e in ipairs(ps) do
    e.min, e.value = 0, e.default
  end
end

-- one labelled row: name on the left, value field on the right
local function param_row(e, label_w, field_w)
  ImGui.Text(ctx, e.name)
  -- the manual's glossed name, on the label, and only when it adds something
  if e.full and e.full ~= e.name then ImGui.SetItemTooltip(ctx, e.full) end
  ImGui.SameLine(ctx, label_w)
  ImGui.SetNextItemWidth(ctx, field_w)
  local changed, v = ImGui.InputInt(ctx, '##' .. e.name, e.value, 0, 0)
  if changed then
    e.value = clamp(v, e.min, e.max) -- InputInt does not clamp
    return true
  end
  return false
end

-- One insertion parameter row. Both panels write 40 03 <addr> and label the
-- event with the selected effect, so the only difference is the label column
-- width and whether the manual's range hint follows the field.
local function efx_param_row(e, label_w, em, show_range)
  if param_row(e, label_w, em * 3.5) then
    local _, msg = insert_sysex(dt1({ 0x40, 0x03, e.addr, e.value }),
                                efx_label(e.name))
    set_status(msg)
  end
  if show_range then
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, e.range)
  end
end

-- Rows the Parameters panel sizes for. The table runs from 3 to 20 rows with
-- a median of 11; 14 of the 64 effects exceed this and scroll, which beats
-- resizing the window on every effect change or leaving it tall and empty.
local EFX_FIT_ROWS = 18

local win_w_cache, efx_win_h

-- Every tab uses this one width, so the window never changes width once it is
-- open. Insertion Effects is what sets it: two panels, each holding the label
-- column, the value field and the widest range text in the table, which is
-- wider than anything the other tabs draw. Measured rather than assumed,
-- since text width depends on the font, and cached: it scans 770 strings and
-- the font is fixed after the first frame.
local function window_w(em)
  if win_w_cache then return win_w_cache end
  local widest = 0
  for _, ps in pairs(EFX_PARAMS) do
    for _, e in ipairs(ps) do
      local w = ImGui.CalcTextSize(ctx, e.range)
      if w > widest then widest = w end
    end
  end
  -- one panel: label column + value field + spacing + range, plus the child's
  -- own padding and a scrollbar; then both panels, the gap and the tab inset.
  local label_w = ImGui.CalcTextSize(ctx, 'RT Hi Accl') + em
  local col = label_w + em * 3.5 + em + widest + em * 2
  -- Leave one full row for the 16 part toggles and their numeric labels.
  win_w_cache = col * 2 + em * 5 + TAB_PAD * 2
  return win_w_cache
end

-- Height the Insertion Effects tab asks for: EFX_FIT_ROWS rows, plus the
-- panel header, the type selector above the panels, the tab inset and the
-- footer. Heights stay per-tab; only the width is shared.
local function efx_window_h(em)
  if efx_win_h then return efx_win_h end
  local row = ImGui.GetFrameHeightWithSpacing(ctx)
  local header = ImGui.GetTextLineHeightWithSpacing(ctx)
                 + ImGui.GetFrameHeightWithSpacing(ctx)
  efx_win_h = EFX_FIT_ROWS * row + header
             + ImGui.GetFrameHeightWithSpacing(ctx) * 4 + em
             + ImGui.GetFrameHeightWithSpacing(ctx) * 2
             + em * 0.5 + TAB_PAD * 2 + em * 4
  return efx_win_h
end

-- Return one preset step when the preceding widget is hovered.
local function mouse_wheel_step()
  if not ImGui.IsItemHovered(ctx) then return 0 end
  local wheel = ImGui.GetMouseWheel(ctx)
  if wheel == 0 then return 0 end
  return wheel > 0 and -1 or 1
end

local function tab_insertion()
  local em = ImGui.GetFontSize(ctx)
  ImGui.Text(ctx, 'EFX Type:')
  -- '##' hides the built-in label, which BeginCombo draws to the right
  ImGui.SetNextItemWidth(ctx, em * 12)
  if ImGui.BeginCombo(ctx, '##efxtype', EFX_TYPES[efx_type][1]) then
    for i, e in ipairs(EFX_TYPES) do
      if ImGui.Selectable(ctx, ('%02d: %s'):format(i - 1, e[1]), i == efx_type) then
        efx_type = i
      end
    end
    ImGui.EndCombo(ctx)
  end
  local wheel = mouse_wheel_step()
  if wheel ~= 0 then
    efx_type = clamp(efx_type + wheel, 1, #EFX_TYPES)
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Insert') then
    local e = EFX_TYPES[efx_type]
    local _, msg = insert_sysex(dt1({ 0x40, 0x03, 0x00, e[2], e[3] }), 'EFX: ' .. e[1])
    set_status(msg)
  end

  ImGui.Text(ctx, 'Parts using EFX:')
  for i = 1, 16 do
    if i > 1 then ImGui.SameLine(ctx) end
    local changed
    changed, efx_parts[i] = ImGui.Checkbox(ctx, ('%d##part%d'):format(i, i), efx_parts[i])
    if changed then
      local _, msg = apply_efx_part(i)
      set_status(msg)
    end
  end

  ImGui.Dummy(ctx, 0, em * 0.5)

  -- Leave TAB_PAD at the right and bottom too: the tab inset only moves the
  -- starting cursor, so a child of size 0 would otherwise fill to the edge.
  local avail_w, avail_h = ImGui.GetContentRegionAvail(ctx)
  local col_w = (avail_w - TAB_PAD - em) / 2
  local col_h = avail_h - TAB_PAD

  -- left: per-effect parameters (40 03 03-16), different for every type
  if ImGui.BeginChild(ctx, 'efx_params', col_w, col_h, ImGui.ChildFlags_Borders) then
    ImGui.Text(ctx, 'Parameters')
    ImGui.Separator(ctx)
    local ps = EFX_PARAMS[efx_type]
    if not ps or #ps == 0 then
      ImGui.TextDisabled(ctx, 'This effect has no parameters.')
    else
      -- Writing a parameter only makes sense once the type itself is on the
      -- tick, so each row sends 40 03 addr on its own.
      -- 'RT Hi Accl' is the widest short name in the table, at 11 characters.
      local label_w = ImGui.CalcTextSize(ctx, 'RT Hi Accl') + em
      for _, e in ipairs(ps) do
        efx_param_row(e, label_w, em, true)
      end
    end
  end
  ImGui.EndChild(ctx)

  ImGui.SameLine(ctx)

  -- right: the sub parameters, shared by every effect type
  if ImGui.BeginChild(ctx, 'efx_sub', col_w, col_h, ImGui.ChildFlags_Borders) then
    ImGui.Text(ctx, 'Insertion Sub')
    ImGui.Separator(ctx)
    local label_w = ImGui.CalcTextSize(ctx, 'Send Level To Reverb') + em
    for _, e in ipairs(EFX_SUB) do
      efx_param_row(e, label_w, em, false)
    end
  end
  ImGui.EndChild(ctx)
end


-- Effects tab: reverb, chorus and delay -------------------------------------

-- Reverb / Chorus / Delay blocks and their presets; see fx_blocks.lua.
local FX_BLOCKS = require 'fx_blocks'

for _, blk in ipairs(FX_BLOCKS) do
  for _, e in ipairs(blk[2]) do e.value = e.default end
end

-- Apply a macro preset: the macro itself at the cursor tick, then each
-- parameter on the following ticks, since two SysEx cannot share a tick.
-- Is there already a run for this block at the cursor? Detected by the macro
-- event itself, since every run starts with one.
local function run_base(take, blk, entry)
  local ppq = cursor_ppq(take)
  local span = (#blk[2] + 1) * cfg.tick_gap
  local idx, pos = find_dt1(take, ppq, { 0x40, 0x01, entry.addr }, span)
  return idx and pos
end

-- Write or rewrite one event of a run at an exact tick.
local function put_at(take, ppq, addr, value)
  local idx = find_dt1(take, ppq, addr, 0)
  local payload = dt1({ addr[1], addr[2], addr[3], value })
  if idx then
    reaper.MIDI_SetTextSysexEvt(take, idx, nil, nil, ppq, -1, payload, false)
  else
    delete_sysex_at(take, ppq)
    reaper.MIDI_InsertTextSysexEvt(take, false, false, ppq, -1, payload)
  end
end

-- Where the 16 part switches already sit near the cursor, as a tick range.
-- Returns nil when none are present.
local function part_run_extent(take, cursor, span)
  local first, last
  for part = 1, 16 do
    local _, pos = find_dt1(take, cursor, part_efx_addr(part), span)
    if pos then
      if not first or pos < first then first = pos end
      if not last or pos > last then last = pos end
    end
  end
  return first, last
end

-- One part's EFX switch. Rewrites this part's own event if it already sits
-- near the cursor, otherwise appends after the last part event so the 16
-- switches gather into one run rather than colliding on a single tick.
apply_efx_part = function(part)
  local addr = part_efx_addr(part)
  local value = efx_parts[part] and 1 or 0
  local name = ('Part %d EFX %s'):format(part, efx_parts[part] and 'ON' or 'OFF')

  local take, ok, msg = begin_write(dt1({ addr[1], addr[2], addr[3], value }), name)
  if not take then return ok, msg end

  local cursor = cursor_ppq(take)
  local span = 16 * cfg.tick_gap
  local existing, at = find_dt1(take, cursor, addr, span)
  local ppq = at
  if not existing then
    local first, last = part_run_extent(take, cursor, span)
    ppq = last and last + cfg.tick_gap or first or cursor
  end

  reaper.Undo_BeginBlock()
  put_at(take, ppq, addr, value)
  delete_label_at(take, ppq)
  put_label(take, ppq, name)
  reaper.MIDI_Sort(take)

  if existing then
    reaper.Undo_EndBlock('Update ' .. name, -1)
    return true, 'Updated ' .. name .. '.'
  end
  reaper.Undo_EndBlock('Insert ' .. name, -1)
  return true, 'Inserted ' .. name .. '.'
end

-- Relabel an existing run, e.g. to Custom once a parameter is edited by hand.
local function relabel_run(take, base, text)
  delete_label_at(take, base)
  put_label(take, base, text)
end

-- Walk a preset in write order: the macro selector first, then every parameter
-- the preset supplies, skipping the macro entry itself. `emit(i, addr, value)`
-- gets each one with its position in the run, and returns false to abort.
-- Both the item and the live path drive this same walk, so the order and the
-- event count cannot drift apart between them.
local function each_preset_event(blk, entry, choice, emit)
  local preset = entry.macros[choice][2]
  local n = 0

  local ok, err = emit(n, { 0x40, 0x01, entry.addr }, choice - 1)
  if not ok then return nil, err end
  n = n + 1

  local i = 0
  for _, e in ipairs(blk[2]) do
    if not e.macros then
      i = i + 1
      if preset[i] then
        e.value = preset[i]
        ok, err = emit(n, { 0x40, 0x01, e.addr }, preset[i])
        if not ok then return nil, err end
        n = n + 1
      end
    end
  end
  return n
end

local function apply_macro(blk, entry, choice)
  local preset_name = entry.macros[choice][1]
  local label = ('%s: %s'):format(blk[1], preset_name)

  local take = get_take()
  if not take then return false, NO_TAKE end

  if cfg.live then
    local n, err = each_preset_event(blk, entry, choice, function(_, addr, value)
      return send_live(dt1({ addr[1], addr[2], addr[3], value }), take)
    end)
    if not n then return false, err end
    return true, ('Sent %s (%d events) to hardware.'):format(preset_name, n)
  end

  -- reuse the run already under the cursor instead of writing a second one
  local base = run_base(take, blk, entry) or cursor_ppq(take)

  reaper.Undo_BeginBlock()
  local n = each_preset_event(blk, entry, choice, function(i, addr, value)
    put_at(take, base + i * cfg.tick_gap, addr, value)
    return true
  end)
  relabel_run(take, base, label)
  reaper.MIDI_Sort(take)
  reaper.Undo_EndBlock('Apply ' .. blk[1] .. ' ' .. preset_name, -1)

  return true, ('Applied %s (%d events).'):format(preset_name, n)
end

-- A hand edit to one parameter of an existing run: rewrite that event and mark
-- the run Custom, since it no longer matches the named preset.
local function edit_in_run(blk, entry, e)
  local take = get_take()
  if not take then return nil end
  local base = run_base(take, blk, entry)
  if not base then return nil end

  if cfg.live then
    local ok, err = send_live(dt1({ 0x40, 0x01, e.addr, e.value }), take)
    if not ok then return false, err end
    return true, 'Sent ' .. e.name .. ' to hardware.'
  end

  reaper.Undo_BeginBlock()
  -- The run is laid out macro-first, so this parameter's slot is its position
  -- among the non-macro entries. Same indexing as each_preset_event.
  local slot = 0
  for _, p in ipairs(blk[2]) do
    if not p.macros then
      slot = slot + 1
      if p == e then
        put_at(take, base + slot * cfg.tick_gap, { 0x40, 0x01, e.addr }, e.value)
        break
      end
    end
  end
  relabel_run(take, base, blk[1] .. ': Custom')
  reaper.MIDI_Sort(take)
  reaper.Undo_EndBlock('Edit ' .. blk[1] .. ' ' .. e.name, -1)
  return true, ('Updated %s (run now Custom).'):format(e.name)
end

-- Settings tab --------------------------------------------------------------

local function tab_settings()
  local em = ImGui.GetFontSize(ctx)
  local label_w = ImGui.CalcTextSize(ctx, 'Tick gap between events') + em

  ImGui.Text(ctx, 'Label events')
  ImGui.SameLine(ctx, label_w)
  local _
  _, cfg.label_events = ImGui.Checkbox(ctx, '##label', cfg.label_events)
  ImGui.SetItemTooltip(ctx, 'Write a readable text event alongside each insert')

  ImGui.Text(ctx, 'Live send mode')
  ImGui.SameLine(ctx, label_w)
  _, cfg.live = ImGui.Checkbox(ctx, '##live', cfg.live)
  ImGui.SetItemTooltip(ctx, 'Send messages immediately to this track hardware output; write nothing to the item')
  ImGui.TextDisabled(ctx, 'Live mode sends immediately and writes nothing to the item.')

  ImGui.Text(ctx, 'Tick gap between events')
  ImGui.SameLine(ctx, label_w)
  -- width must cover the field plus both step buttons, which are square and
  -- one frame high each
  ImGui.SetNextItemWidth(ctx, em * 3.5 + ImGui.GetFrameHeight(ctx) * 2)
  local changed, v = ImGui.InputInt(ctx, '##gap', cfg.tick_gap, 1, 1)
  if changed then cfg.tick_gap = clamp(v, 1, 96) end
  ImGui.SetItemTooltip(ctx, 'Spacing between the events a macro writes. Too small and the hardware cannot keep up.')
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, ('(applies to the next macro; now %d)'):format(cfg.tick_gap))
end

local function tab_effects()
  local em = ImGui.GetFontSize(ctx)
  if ImGui.BeginTabBar(ctx, 'fxtabs') then
    for _, blk in ipairs(FX_BLOCKS) do
      if ImGui.BeginTabItem(ctx, blk[1]) then
        ImGui.Dummy(ctx, 0, em * 0.4)
        local label_w = ImGui.CalcTextSize(ctx, 'Time Ratio Right') + em
        for _, e in ipairs(blk[2]) do
          if e.macros then
            -- preset selector: writes the macro plus every parameter it sets
            ImGui.Text(ctx, e.name)
            ImGui.SameLine(ctx, label_w)
            ImGui.SetNextItemWidth(ctx, em * 10)
            -- Preview reads Custom once a parameter no longer matches the
            -- preset; Custom is never a selectable option.
            local preview = e.custom and 'Custom' or e.macros[e.value + 1][1]
            if ImGui.BeginCombo(ctx, '##' .. e.name, preview) then
              for i, m in ipairs(e.macros) do
                if ImGui.Selectable(ctx, m[1], not e.custom and i == e.value + 1) then
                  e.value = i - 1
                  e.custom = false
                  local _, msg = apply_macro(blk, e, i)
                  set_status(msg)
                end
              end
              ImGui.EndCombo(ctx)
            end
            local wheel = mouse_wheel_step()
            if wheel ~= 0 then
              local choice = clamp(e.value + 1 + wheel, 1, #e.macros)
              if choice ~= e.value + 1 or e.custom then
                e.value = choice - 1
                e.custom = false
                local _, msg = apply_macro(blk, e, choice)
                set_status(msg)
              end
            end
          elseif param_row(e, label_w, em * 3.5) then
            local name = blk[1] .. ' ' .. e.name
            -- inside an existing run: rewrite that event and mark it Custom.
            -- otherwise insert a standalone event at the cursor.
            local macro_entry = blk[2][1]
            if macro_entry.macros then macro_entry.custom = true end
            local ok, msg = edit_in_run(blk, macro_entry, e)
            if ok == nil then
              ok, msg = insert_sysex(dt1({ 0x40, 0x01, e.addr, e.value }), name)
            end
            set_status(msg)
          end
        end
        ImGui.EndTabItem(ctx)
      end
    end
    ImGui.EndTabBar(ctx)
  end
end

-- window: tabs, footer and the frame loop -----------------------------------

-- { label, draw function, height }. Height is the window height the tab asks
-- for when selected, and defaults to WIN_H. It may be a function, since
-- measuring text needs a live context and this table is built before there is
-- one. Width is not per-tab: every tab uses window_w.
local TABS = {
  { 'Master', tab_master },
  { 'Insertion Effects', tab_insertion, efx_window_h },
  { 'Effects', tab_effects, 520 },
  { 'Settings', tab_settings },
}

local active_tab, pending_h

-- Footer row: actions left, status right. Lives outside the scrolling body so
-- it is always visible and never contributes to the body's scroll range.
local function footer()
  ImGui.Separator(ctx)
  -- keep the row at button height even though only text sits here now
  ImGui.Dummy(ctx, 0, ImGui.GetFrameHeight(ctx))
  if status ~= '' then
    ImGui.SameLine(ctx)
    local avail_w = ImGui.GetContentRegionAvail(ctx)

    -- Truncate to the space the button leaves, so a long message cannot spill
    -- past the window edge. The full text stays available on hover.
    local shown, text_w = status, ImGui.CalcTextSize(ctx, status)
    if text_w > avail_w then
      local ell_w = ImGui.CalcTextSize(ctx, '...')
      repeat
        shown = shown:sub(1, #shown - 1)
        text_w = ImGui.CalcTextSize(ctx, shown)
      until text_w + ell_w <= avail_w or #shown == 0
      shown = shown .. '...'
      text_w = ImGui.CalcTextSize(ctx, shown)
    end

    local x, y = ImGui.GetCursorPos(ctx)
    -- centre the text against the taller button box on this row
    local frame_y = select(2, ImGui.GetStyleVar(ctx, ImGui.StyleVar_FramePadding))
    ImGui.SetCursorPos(ctx, x + math.max(0, avail_w - text_w), y + frame_y)
    ImGui.Text(ctx, shown)
    if shown ~= status then ImGui.SetItemTooltip(ctx, status) end
  end
end

local function loop()
  if status ~= '' and reaper.time_precise() - status_time > STATUS_SECS then
    status = ''
  end

  ImGui.PushFont(ctx, font, FONT_SIZE)
  -- Apply the default size on the first frame only: Cond_Always so a size
  -- saved in ReaImGui's ini cannot override it, then stop so the window
  -- stays resizable. (Cond_FirstUseEver would defer to that saved size.)
  -- FONT_SIZE, not GetFontSize: these run before Begin, where there is no
  -- current window to read a size from. PushFont above was given the same
  -- value, so the text CalcTextSize measures here is the text that is drawn.
  if first_frame then
    -- The shared width from the first frame on, so the window never opens at
    -- one width and jumps to another on the first tab change.
    ImGui.SetNextWindowSize(ctx, window_w(FONT_SIZE), WIN_H, ImGui.Cond_Always)
    first_frame = false
  elseif pending_h then
    -- Height requested by the tab selected last frame; the width is the same
    -- for every tab, so only the height changes here.
    ImGui.SetNextWindowSize(ctx, window_w(FONT_SIZE), pending_h,
                            ImGui.Cond_Always)
    pending_h = nil
  end
  local visible, open = ImGui.Begin(ctx, 'PAGER - Effects Editor', true)
  if visible then
    -- Reserve one frame's height for the footer. ChildFlags_None: no
    -- ResizeY, so the divider is not a drag handle.
    -- false means collapsed or fully clipped: skip the contents, but still
    -- call EndChild, which unlike EndTabBar is unconditional.
    -- Reserve the footer: its button row plus the separator above it.
    local footer_h = ImGui.GetFrameHeightWithSpacing(ctx)
                   + select(2, ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing))
    if ImGui.BeginChild(ctx, 'body', 0, -footer_h, ImGui.ChildFlags_None) then
      if ImGui.BeginTabBar(ctx, 'tabs') then
        for _, tab in ipairs(TABS) do
          if ImGui.BeginTabItem(ctx, tab[1]) then
            -- Record the wanted height on a tab change; SetNextWindowSize
            -- must be called before Begin, so the loop applies it next frame.
            if active_tab ~= tab[1] then
              active_tab = tab[1]
              -- height may be a function: measuring needs a live context
              local h = tab[3]
              pending_h = (type(h) == 'function'
                           and h(ImGui.GetFontSize(ctx)) or h) or WIN_H
            end
            -- inset tab contents so controls are not glued to the corner
            local cx, cy = ImGui.GetCursorPos(ctx)
            ImGui.SetCursorPos(ctx, cx + TAB_PAD, cy + TAB_PAD)
            ImGui.BeginGroup(ctx)
            tab[2]()
            ImGui.EndGroup(ctx)
            ImGui.EndTabItem(ctx)
          end
        end
        ImGui.EndTabBar(ctx)
      end
    end
    ImGui.EndChild(ctx)


    footer()
    ImGui.End(ctx)
  end

  ImGui.PopFont(ctx)

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
