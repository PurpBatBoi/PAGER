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
local json = require 'json'
local Theme = require 'theme'
local ctx = ImGui.CreateContext('PAGER - Effects Editor')

-- native OS window frame instead of ImGui's drawn title bar
ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, 0)

local FONT_SIZE = 15
local WIN_H = 300 -- default height; the width is measured by window_w
local TAB_PAD = 18 -- inset for tab contents
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
local part_eq_addr = GS.part_eq_addr

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

-- One labelled row: name on the left, horizontal slider on the right.
-- Horizontal SliderInt (unlike the VSliderInt this replaced) natively
-- supports Ctrl+Click text entry, so there is no separate input box to
-- maintain here -- same widget shape as the Insertion Effects rows.
local function master_fader(m, label_w, slider_w)
  ImGui.Text(ctx, m.name)
  ImGui.SameLine(ctx, label_w)
  ImGui.SetNextItemWidth(ctx, slider_w)

  -- Tune is held and dragged as raw tenths-of-a-Hz so the slider (an int
  -- slider; SliderInt's min/max/value are all C ints) stays exact -- a Hz
  -- format string here would need a float, which SliderInt cannot take.
  -- format only ever gets one %d substitution (the value itself), so the
  -- decimal point cannot be inserted through it either -- the whole label
  -- is rebuilt as literal text every frame instead, same trick the enum
  -- rows on the Insertion Effects tab use to show a name instead of a byte.
  local fmt = '%d'
  if m.hz then fmt = ('%d.%d Hz'):format(m.value // 10, m.value % 10) end

  -- ClampOnInput: a value typed via Ctrl+Click is otherwise not clamped and
  -- can go out of bounds, which would not fit in a 7-bit MIDI data byte.
  local changed, v = ImGui.SliderInt(ctx, '##s' .. m.name, m.value,
                                     m.min, m.max, fmt,
                                     ImGui.SliderFlags_ClampOnInput)
  if changed then m.value = v end
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

  return send
end

local function tab_master()
  local em = ImGui.GetFontSize(ctx)
  local label_w = ImGui.CalcTextSize(ctx, 'Key-Shift') + em
  local slider_w = em * 16

  for _, m in ipairs(MASTERS) do
    if master_fader(m, label_w, slider_w) then
      local _, msg = insert_sysex(m.build(m.value), 'Master ' .. m.name)
      set_status(msg)
    end
  end

  ImGui.Dummy(ctx, 0, em * 0.5)
  for i, r in ipairs(RESETS) do
    if i > 1 then ImGui.SameLine(ctx) end
    if ImGui.Button(ctx, r.name) then
      local _, msg = insert_sysex(r.build(), r.name)
      set_status(msg)
    end
  end
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

-- Per-part EQ ON/OFF (40 4x 20, manual p.60/240). Unlike EFX, the hardware
-- default is every part ON, so these checkboxes start checked.
local eq_parts = {}
local apply_eq_part
for i = 1, 16 do
  eq_parts[i] = true
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
-- min is not 0 throughout: 194 of 770 parameters start above 0 (Low Gain is
-- 52-76, not 0-127) for the signed-looking ones (Pan L63-0-R63, Feedback
-- -98%-+98%), which are stored offset so the true minimum is a real byte
-- value rather than the displayed one. efx_params.lua carries this min from
-- GSAE's INSERTION.json; `or 0` covers a stale table built before it did.
for _, ps in pairs(EFX_PARAMS) do
  for _, e in ipairs(ps) do
    e.min, e.value = e.min or 0, e.default
  end
end

-- Named Insertion Effects presets live outside the ReaPack install so they
-- survive updates and can be shared as one readable file.
local efx_preset_name = ''
local efx_preset_sel = {}
local efx_presets
local efx_default_presets = {}
local fx_preset_sel = {}
local preset_save_context
local FX_BLOCKS
local system_presets_for
local PATH_SEP = package.config:sub(1, 1)

local function efx_presets_dir()
  local root = reaper.GetResourcePath()
  if root:sub(-1) ~= PATH_SEP then root = root .. PATH_SEP end
  return root .. 'presets' .. PATH_SEP .. 'PAGER'
end

local function efx_presets_path()
  return efx_presets_dir() .. PATH_SEP .. 'user_presets.json'
end

local function preset_array(v)
  if type(v) ~= 'table' then return false end
  for k in pairs(v) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
  end
  return true
end

local function number_array(v)
  if not preset_array(v) then return false end
  local max = 0
  for i in pairs(v) do if i > max then max = i end end
  if max ~= #v then return false end
  for i = 1, max do
    if type(v[i]) ~= 'number' then return false end
  end
  return true
end

local function efx_presets_read()
  local f = io.open(efx_presets_path(), 'r')
  if not f then
    efx_presets = {}
    return efx_presets
  end
  local text = f:read('a')
  f:close()
  local ok, decoded = pcall(json.decode, text)
  if not ok then
    set_status('Could not read presets: ' .. tostring(decoded))
    return efx_presets or {}
  end
  if not preset_array(decoded) then
    set_status('Could not read presets: expected an array.')
    return efx_presets or {}
  end
  ---@cast decoded table
  local decoded_array = decoded
  local list = {}
  for _, p in ipairs(decoded_array) do
    local valid_efx = type(p) == 'table' and type(p.efx) == 'string'
      and number_array(p.vals) and number_array(p.sub or {})
    local valid_fx = type(p) == 'table' and type(p.fx) == 'string'
      and type(p.macro) == 'number' and number_array(p.vals)
    if type(p) == 'table' and type(p.name) == 'string'
       and (valid_efx or valid_fx) then
      list[#list + 1] = p
    end
  end
  efx_presets = list
  return list
end

local function efx_values(values)
  local out = {}
  for _, v in ipairs(values) do out[#out + 1] = ('%.14g'):format(v) end
  return '[' .. table.concat(out, ', ') .. ']'
end

local function efx_preset_encode(p)
  if p.fx then
    return ('  { "fx": %s, "fx_index": %s, "name": %s,\n    "macro": %s,\n    "vals": %s }')
      :format(json.encode(p.fx), tostring(p.fx_index or 0), json.encode(p.name),
              tostring(p.macro), efx_values(p.vals))
  end
  return ('  { "efx": %s, "efx_index": %s, "name": %s,\n    "vals": %s,\n    "sub":  %s }')
    :format(json.encode(p.efx or ''), tostring(p.efx_index or 0),
            json.encode(p.name), efx_values(p.vals), efx_values(p.sub))
end

local function efx_presets_write(list)
  table.sort(list, function(a, b)
    if (a.efx_index or 0) ~= (b.efx_index or 0) then
      return (a.efx_index or 0) < (b.efx_index or 0)
    end
    return a.name < b.name
  end)
  local dir = efx_presets_dir()
  reaper.RecursiveCreateDirectory(dir, 0)
  local f, err = io.open(efx_presets_path(), 'w')
  if not f then
    set_status('Could not save presets: ' .. tostring(err))
    return false
  end
  local blocks = {}
  for _, p in ipairs(list) do blocks[#blocks + 1] = efx_preset_encode(p) end
  f:write('[\n', table.concat(blocks, ',\n'), '\n]\n')
  f:close()
  efx_presets = efx_presets_read()
  return true
end

local function efx_presets_for(t)
  local name = EFX_TYPES[t][1]
  local default = efx_default_presets[t]
  if not default then
    default = { efx = name, efx_index = t, name = 'Default', vals = {}, sub = {} }
    for _, e in ipairs(EFX_PARAMS[t] or {}) do default.vals[#default.vals + 1] = e.default end
    for _, e in ipairs(EFX_SUB) do default.sub[#default.sub + 1] = e.default end
    efx_default_presets[t] = default
  end
  if efx_preset_sel[t] == nil then efx_preset_sel[t] = default end
  local result = { default }
  for _, p in ipairs(efx_presets or {}) do
    if p.name ~= 'Default' and (p.efx == name or (p.efx == nil and p.efx_index == t)) then
      result[#result + 1] = p
    end
  end
  return result
end

local function efx_preset_apply(p)
  local ps = EFX_PARAMS[efx_type] or {}
  if #p.vals ~= #ps or #p.sub ~= #EFX_SUB then
    return false, ('Preset %q has the wrong parameter count.'):format(p.name)
  end
  for i, e in ipairs(ps) do
    local v = tonumber(p.vals[i])
    e.value = v and clamp(math.floor(v), e.min, e.max) or e.default
  end
  for i, e in ipairs(EFX_SUB) do
    local v = tonumber(p.sub[i])
    e.value = v and clamp(math.floor(v), e.min, e.max) or e.default
  end
  return true
end

local function preset_save(context, raw_name)
  local name = raw_name:match('^%s*(.-)%s*$'):sub(1, 32)
  if name == '' then
    set_status('Preset needs a name.')
    return false
  end
  if name == 'Default' and context.kind == 'efx' then
    set_status('Default is built in; choose another name.')
    return false
  end

  local list = efx_presets or {}
  local p
  if context.kind == 'efx' then
    p = { efx = EFX_TYPES[efx_type][1], efx_index = efx_type,
          name = name, vals = {}, sub = {} }
    for _, e in ipairs(EFX_PARAMS[efx_type] or {}) do p.vals[#p.vals + 1] = e.value end
    for _, e in ipairs(EFX_SUB) do p.sub[#p.sub + 1] = e.value end
  else
    p = { fx = context.blk[1], fx_index = context.index, name = name,
          macro = context.entry.value + 1, vals = {} }
    for _, e in ipairs(context.blk[2]) do
      if not e.macros then p.vals[#p.vals + 1] = e.value end
    end
  end
  local replaced
  for i, old in ipairs(list) do
    local same_type = context.kind == 'efx'
      and (old.efx == p.efx or old.efx_index == p.efx_index)
      or context.kind == 'fx'
      and (old.fx == p.fx or old.fx_index == p.fx_index)
    if same_type and old.name == name then
      list[i], replaced = p, true
      break
    end
  end
  if not replaced then list[#list + 1] = p end
  if not efx_presets_write(list) then return false end
  if context.kind == 'efx' then
    for _, saved in ipairs(efx_presets_for(efx_type)) do
      if saved.name == name then efx_preset_sel[efx_type] = saved break end
    end
  else
    for _, saved in ipairs(system_presets_for(context.blk, context.entry, context.index)) do
      if saved.name == name then fx_preset_sel[context.blk[1]] = saved break end
    end
  end
  set_status("Saved '" .. name .. "' to " .. efx_presets_path())
  return true
end

-- Insert the selected preset values.
-- Parameters share the 40 03 address space, so they are spaced like a macro
-- run rather than being placed on one tick and replacing each other.
local put_at
local relabel_run
local function insert_efx_preset(p)
  local ps = EFX_PARAMS[efx_type] or {}
  if #p.vals ~= #ps or #p.sub ~= #EFX_SUB then
    return false, ('Preset %q has the wrong parameter count.'):format(p.name)
  end
  local events = {}
  for i, e in ipairs(ps) do
    local v = tonumber(p.vals[i])
    if not v then return false, ('Preset %q has an invalid parameter value.'):format(p.name) end
    v = clamp(math.floor(v), e.min, e.max)
    events[#events + 1] = { addr = { 0x40, 0x03, e.addr }, value = v }
  end
  for i, e in ipairs(EFX_SUB) do
    local v = tonumber(p.sub[i])
    if not v then return false, ('Preset %q has an invalid sub value.'):format(p.name) end
    v = clamp(math.floor(v), e.min, e.max)
    events[#events + 1] = { addr = { 0x40, 0x03, e.addr }, value = v }
  end

  local take = get_take()
  if not take then return false, NO_TAKE end
  local name = ('EFX: %s | %s (%d parameters)'):format(EFX_TYPES[efx_type][1], p.name, #events)
  if cfg.live then
    for _, event in ipairs(events) do
      local ok, err = send_live(dt1({ event.addr[1], event.addr[2], event.addr[3], event.value }), take)
      if not ok then return false, err end
    end
    return true, 'Sent ' .. name .. ' to hardware.'
  end

  local base = cursor_ppq(take)
  reaper.Undo_BeginBlock()
  for i, event in ipairs(events) do
    put_at(take, base + (i - 1) * cfg.tick_gap, event.addr, event.value)
  end
  put_label(take, base, name)
  reaper.MIDI_Sort(take)
  reaper.Undo_EndBlock('Insert ' .. name, -1)
  return true, 'Inserted ' .. name .. ' at cursor.'
end

efx_presets = efx_presets_read()

-- One labelled row: name on the left, slider on the right, spanning the
-- parameter's own min-max (Reverb/Chorus/Delay params carry no manual range
-- hint the way insertion effects do, so there is nothing to show beside the
-- field). Parameter edits stay in memory until the tab's Insert preset button
-- is pressed; double-click still resets to the default.
-- fmt for a param_row slider: e.value stays the raw byte in every case, only
-- the displayed text changes. e.db shows the byte as a signed dB offset from
-- 64 (the EQ gains); e.enum shows a name instead of a number (mirrors
-- enum_parts below, for blocks too small to need that caching).
local function param_row_fmt(e)
  if e.db then return ('%+d dB'):format(e.value - 64) end
  -- parenthesised: gsub also returns a replacement count, which would ride
  -- along into the caller's next argument slot.
  if e.enum then return ((e.enum[e.value + 1] or '?'):gsub('%%', '%%%%')) end
  return '%d'
end

local function param_row(e, label_w, field_w)
  ImGui.Text(ctx, e.name)
  -- the manual's glossed name, on the label, and only when it adds something
  if e.full and e.full ~= e.name then ImGui.SetItemTooltip(ctx, e.full) end
  ImGui.SameLine(ctx, label_w)
  ImGui.SetNextItemWidth(ctx, field_w)
  -- ClampOnInput: a value typed via Ctrl+Click is otherwise not clamped and
  -- can go out of bounds, which would not fit in a 7-bit MIDI data byte.
  local changed, v = ImGui.SliderInt(ctx, '##' .. e.name, e.value,
                                      e.min, e.max, param_row_fmt(e),
                                      ImGui.SliderFlags_ClampOnInput)
  if changed then e.value = v end
  if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
    e.resetting = true
  end
  if e.resetting then
    e.value = e.default
    if not ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left) then e.resetting = false end
  end

  return ImGui.IsItemDeactivatedAfterEdit(ctx)
end

-- Width of an insertion parameter's value field: wide enough for a slider,
-- and (see EFX_FIELD_W below) at least as wide as the widest enum label,
-- since an enum slider draws that label inside its track.
local EFX_FIELD_W_EM = 6

-- range is an enum ('Small/BltIn/2-Stk/3-Stk') when splitting on '/' yields
-- exactly max+1 pieces -- the gate that rejects numeric ranges which merely
-- contain a slash, like '200-990ms/1sec' or '315-8k/Bypass'. Parsed once and
-- cached on the entry, mirroring win_w_cache below.
local function enum_parts(e)
  if e.enum_parts ~= nil then return e.enum_parts end
  if not e.range then -- EFX_SUB has no range/manual hint at all
    e.enum_parts = false
    return false
  end
  local parts = {}
  for p in e.range:gmatch('[^/]+') do parts[#parts + 1] = p end
  if e.min == 0 and #parts == e.max + 1 then
    e.enum_parts = parts
  else
    e.enum_parts = false
  end
  return e.enum_parts
end

-- One insertion parameter row: a slider spanning the true hardware range.
-- Enum parameters (Off/On, Small/BltIn/2-Stk/3-Stk) reuse the same SliderInt
-- by passing the choice name as the format string instead of '%d' -- the
-- documented way to show a name instead of a number (ReaImGui demo.lua,
-- 'slider enum') -- so the slider reads 'Small' rather than '0'. ClampOnInput
-- is required, not cosmetic: by default Ctrl+Click text entry on a slider can
-- go out of bounds, and that value would otherwise be sent to the hardware.
local function efx_param_row(e, label_w, em, show_range)
  ImGui.Text(ctx, e.name)
  if e.full and e.full ~= e.name then ImGui.SetItemTooltip(ctx, e.full) end
  ImGui.SameLine(ctx, label_w)
  ImGui.SetNextItemWidth(ctx, em * EFX_FIELD_W_EM)

  local parts = enum_parts(e)
  local fmt = '%d'
  if parts then
    -- no enum label contains '%' today, but escape defensively since this
    -- string becomes a printf format
    fmt = (parts[e.value + 1] or '?'):gsub('%%', '%%%%')
  end

  local changed, v = ImGui.SliderInt(ctx, '##' .. e.name, e.value,
                                      e.min, e.max, fmt,
                                      ImGui.SliderFlags_ClampOnInput)
  if changed then e.value = v end
  -- Double-click resets to the default. Parameter edits are state-only;
  -- Insert preset is the explicit write action for this tab.
  if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
    e.resetting = true
  end
  if e.resetting then
    e.value = e.default
    if not ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left) then e.resetting = false end
  end
  if show_range and not parts then
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, e.range)
  end
end

-- Rows the Parameters panel sizes for. The table runs from 3 to 20 rows with
-- a median of 11; 14 of the 64 effects exceed this and scroll, which beats
-- resizing the window on every effect change or leaving it tall and empty.
local EFX_FIT_ROWS = 18

local win_w_cache, efx_win_h, fx_win_h

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
  -- The field uses EFX_FIELD_W_EM, not em*3.5 as it did before sliders: an
  -- enum slider draws its choice name inside the track, so the field itself
  -- must fit the widest range piece, not just a byte's worth of digits.
  local label_w = ImGui.CalcTextSize(ctx, 'RT Hi Accl') + em
  local col = label_w + em * EFX_FIELD_W_EM + em + widest + em * 2
  -- Leave one full row for the 16 part toggles and their numeric labels.
  -- One em covers the child gap and the remaining measured allowances; keep
  -- the outer size tight now that the font and tab inset are compact.
  win_w_cache = col * 2 + em * 4 + TAB_PAD * 2
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

local function draw_preset_popup(em)
  if not ImGui.BeginPopupModal(ctx, 'Save preset', nil, ImGui.WindowFlags_AlwaysAutoResize) then return end
  ImGui.Text(ctx, 'Preset name:')
  ImGui.SetNextItemWidth(ctx, em * 18)
  local changed, v = ImGui.InputText(ctx, '##presetname', efx_preset_name)
  if changed then efx_preset_name = v end
  if ImGui.Button(ctx, 'OK', em * 6, 0) then
    if preset_save(preset_save_context, efx_preset_name) then ImGui.CloseCurrentPopup(ctx) end
  end
  ImGui.SetItemDefaultFocus(ctx)
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Cancel', em * 6, 0) then ImGui.CloseCurrentPopup(ctx) end
  ImGui.EndPopup(ctx)
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

  local presets = efx_presets_for(efx_type)
  local selected = efx_preset_sel[efx_type]
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, 'Preset:')
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, em * 12)
  local preview = selected and selected.name or '(none)'
  if ImGui.BeginCombo(ctx, '##efxpreset', preview) then
    for _, p in ipairs(presets) do
      if ImGui.Selectable(ctx, p.name, p == selected) then
        local ok, msg = efx_preset_apply(p)
        if ok then
          efx_preset_sel[efx_type] = p
          set_status(("Loaded '%s' (values only; insert to send)."):format(p.name))
        else
          set_status(msg)
        end
      end
    end
    ImGui.EndCombo(ctx)
  end
  local preset_wheel = mouse_wheel_step()
  if preset_wheel ~= 0 and #presets > 0 then
    local i = 1
    for n, p in ipairs(presets) do if p == selected then i = n end end
    i = clamp(i + preset_wheel, 1, #presets)
    local p = presets[i]
    local ok, msg = efx_preset_apply(p)
    if ok then
      efx_preset_sel[efx_type] = p
      set_status(("Loaded '%s' (values only; insert to send)."):format(p.name))
    else set_status(msg) end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, '+') then
    efx_preset_name = ''
    preset_save_context = { kind = 'efx' }
    ImGui.OpenPopup(ctx, 'Save preset')
  end
  ImGui.SetItemTooltip(ctx, 'Save a preset to ' .. efx_presets_path())
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, '-') then
    if selected and selected.name ~= 'Default' then
      for i, p in ipairs(efx_presets) do if p == selected then table.remove(efx_presets, i) break end end
      efx_preset_sel[efx_type] = nil
      if efx_presets_write(efx_presets) then set_status("Deleted '" .. selected.name .. "'.") end
    end
  end
  ImGui.SetItemTooltip(ctx, 'Delete selected preset')
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Insert preset##efxpresetinsert') then
    local _, msg = insert_efx_preset(selected)
    set_status(msg)
  end
  ImGui.SetItemTooltip(ctx, 'Insert the selected preset at the playhead')

  draw_preset_popup(em)

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
FX_BLOCKS = require 'fx_blocks'

for _, blk in ipairs(FX_BLOCKS) do
  for _, e in ipairs(blk[2]) do e.value = e.default end
end

-- Built-in preset tables, cached per block so the same table is returned
-- every call. system_presets_for used to build a fresh table for each
-- built-in on every call, which broke identity comparisons that persist a
-- selection across frames (fx_preset_sel, and the mouse-wheel step in
-- fx_preset_row): the wheel handler would look up last frame's selected
-- table in this frame's freshly-built list, never find it by == , and
-- silently fall back to index 1 -- stepping always relative to the first
-- preset instead of the actual selection. efx_presets_for/efx_default_presets
-- already avoid this for the Insertion Effects tab; this mirrors that.
local fx_default_presets = {}

system_presets_for = function(blk, entry, block_index)
  local cached = fx_default_presets[blk[1]]
  if not cached then
    cached = {}
    for i, macro in ipairs(entry.macros) do
      cached[i] = { fx = blk[1], fx_index = block_index, name = macro[1],
                     macro = i, vals = macro[2], built_in = true }
    end
    fx_default_presets[blk[1]] = cached
  end
  local result = {}
  for _, p in ipairs(cached) do result[#result + 1] = p end
  for _, p in ipairs(efx_presets or {}) do
    if p.fx == blk[1] or (p.fx == nil and p.fx_index == block_index) then
      result[#result + 1] = p
    end
  end
  if fx_preset_sel[blk[1]] == nil then fx_preset_sel[blk[1]] = result[1] end
  return result
end

local function system_preset_apply(blk, entry, p)
  local count = 0
  for _, e in ipairs(blk[2]) do if not e.macros then count = count + 1 end end
  if #p.vals ~= count or type(p.macro) ~= 'number' then
    return false, ('Preset %q has the wrong parameter count.'):format(p.name)
  end
  entry.value = clamp(math.floor(p.macro) - 1, 0, #entry.macros - 1)
  entry.custom = not p.built_in
  local i = 0
  for _, e in ipairs(blk[2]) do
    if not e.macros then
      i = i + 1
      e.value = clamp(math.floor(p.vals[i]), e.min, e.max)
    end
  end
  return true
end

-- Apply a macro preset: the macro itself at the cursor tick, then each
-- parameter on the following ticks, since two SysEx cannot share a tick.
-- Is there already a run for this block at the cursor? Detected by the macro
-- event itself, since every run starts with one. Blocks with no hardware
-- macro register (EQ) have entry.addr == nil and so no event to find by;
-- fall back to scanning for the run's first real parameter instead.
local function run_base(take, blk, entry)
  local ppq = cursor_ppq(take)
  local span = (#blk[2] + 1) * cfg.tick_gap
  if entry.addr then
    local idx, pos = find_dt1(take, ppq, { 0x40, blk.addr_mid, entry.addr }, span)
    return idx and pos
  end
  for _, e in ipairs(blk[2]) do
    if not e.macros then
      local idx, pos = find_dt1(take, ppq, { 0x40, blk.addr_mid, e.addr }, span)
      if idx then return pos end
    end
  end
  return nil
end

-- Write or rewrite one event of a run at an exact tick.
put_at = function(take, ppq, addr, value)
  local idx = find_dt1(take, ppq, addr, 0)
  local payload = dt1({ addr[1], addr[2], addr[3], value })
  if idx then
    reaper.MIDI_SetTextSysexEvt(take, idx, nil, nil, ppq, -1, payload, false)
  else
    delete_sysex_at(take, ppq)
    reaper.MIDI_InsertTextSysexEvt(take, false, false, ppq, -1, payload)
  end
end

local function insert_system_preset(blk, entry, p)
  local take = get_take()
  if not take then return false, NO_TAKE end
  local name = ('%s: %s'):format(blk[1], p.name)
  -- Both paths below write each entry's current value -- the preset combo
  -- has already applied p.vals into them, so what is on screen is what goes
  -- out. EQ has no hardware macro register (entry.addr == nil), so it writes
  -- no macro event, just the parameters.
  local count = entry.addr and 1 or 0
  for _, e in ipairs(blk[2]) do
    if not e.macros then count = count + 1 end
  end
  local macro_value = clamp(entry.value, 0, #entry.macros - 1)

  if cfg.live then
    if entry.addr then
      local macro_ok, macro_err = send_live(dt1({ 0x40, blk.addr_mid, entry.addr, macro_value }), take)
      if not macro_ok then return false, macro_err end
    end
    for _, e in ipairs(blk[2]) do
      if not e.macros then
        local sent, err = send_live(dt1({ 0x40, blk.addr_mid, e.addr, e.value }), take)
        if not sent then return false, err end
      end
    end
    return true, 'Sent ' .. name .. ' (' .. count .. ' events) to hardware.'
  end

  local base = cursor_ppq(take)
  reaper.Undo_BeginBlock()
  local tick = 0
  if entry.addr then
    put_at(take, base, { 0x40, blk.addr_mid, entry.addr }, macro_value)
    tick = 1
  end
  for _, e in ipairs(blk[2]) do
    if not e.macros then
      put_at(take, base + tick * cfg.tick_gap, { 0x40, blk.addr_mid, e.addr }, e.value)
      tick = tick + 1
    end
  end
  relabel_run(take, base, name)
  reaper.MIDI_Sort(take)
  reaper.Undo_EndBlock('Insert ' .. name, -1)
  return true, 'Inserted ' .. name .. ' (' .. count .. ' events) at cursor.'
end

-- Write only parameters that differ from the selected preset. The macro is
-- deliberately excluded: this action is for parameter edits, not for
-- changing the effect type. When a run already exists, preserve each
-- parameter's normal slot; otherwise place the changed parameters in a new
-- parameter-only run starting at the cursor.
local function insert_system_preset_changes(blk, entry, p)
  local take = get_take()
  if not take then return false, NO_TAKE end

  -- Tick offset within a run: right after the macro tick when the block has
  -- one (Reverb/Chorus/Delay), or from tick 0 when it does not (EQ) -- must
  -- match the layout insert_system_preset writes.
  local tick_base = entry.addr and 1 or 0

  local changed = {}
  local value_index = 0
  for _, e in ipairs(blk[2]) do
    if not e.macros then
      local baseline = tonumber(p.vals[value_index + 1])
      if baseline == nil then
        return false, ('Preset %q has an invalid parameter value.'):format(p.name)
      end
      if e.value ~= baseline then
        changed[#changed + 1] = { entry = e, slot = tick_base + value_index, value = e.value }
      end
      value_index = value_index + 1
    end
  end

  if #changed == 0 then
    return true, 'No changed parameters to insert.'
  end

  local name = ('%s: changed parameters'):format(blk[1])
  if cfg.live then
    for _, item in ipairs(changed) do
      local sent, err = send_live(dt1({ 0x40, blk.addr_mid, item.entry.addr, item.value }), take)
      if not sent then return false, err end
    end
    return true, ('Sent %s (%d events) to hardware.'):format(name, #changed)
  end

  local existing_base = run_base(take, blk, entry)
  local base = existing_base or cursor_ppq(take)
  reaper.Undo_BeginBlock()
  for changed_index, item in ipairs(changed) do
    -- Existing runs retain the normal macro-first parameter slots. A new
    -- parameter-only insertion starts at the playhead and packs only the
    -- changed values.
    local offset = existing_base and item.slot or (changed_index - 1)
    local ppq = base + offset * cfg.tick_gap
    put_at(take, ppq, { 0x40, blk.addr_mid, item.entry.addr }, item.value)
  end
  relabel_run(take, base, name)
  reaper.MIDI_Sort(take)
  reaper.Undo_EndBlock('Insert ' .. name, -1)
  return true, ('Inserted %s (%d events) at cursor.'):format(name, #changed)
end

-- Where the 16 part switches already sit near the cursor, as a tick range.
-- Returns nil when none are present. addr_fn is part_efx_addr or
-- part_eq_addr -- the two switches never share a run, so each is found by
-- its own address.
local function part_run_extent(take, cursor, span, addr_fn)
  local first, last
  for part = 1, 16 do
    local _, pos = find_dt1(take, cursor, addr_fn(part), span)
    if pos then
      if not first or pos < first then first = pos end
      if not last or pos > last then last = pos end
    end
  end
  return first, last
end

-- One part's switch (EFX or EQ). Rewrites this part's own event if it
-- already sits near the cursor, otherwise appends after the last part event
-- so the 16 switches gather into one run rather than colliding on a tick.
-- addr_fn picks the switch; parts holds the 16 checkbox booleans; word names
-- it in the event label ('EFX' or 'EQ').
local function apply_part_switch(part, addr_fn, parts, word)
  local addr = addr_fn(part)
  local value = parts[part] and 1 or 0
  local name = ('Part %d %s %s'):format(part, word, parts[part] and 'ON' or 'OFF')

  local take, ok, msg = begin_write(dt1({ addr[1], addr[2], addr[3], value }), name)
  if not take then return ok, msg end

  local cursor = cursor_ppq(take)
  local span = 16 * cfg.tick_gap
  local existing, at = find_dt1(take, cursor, addr, span)
  local ppq = at
  if not existing then
    local first, last = part_run_extent(take, cursor, span, addr_fn)
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

apply_efx_part = function(part) return apply_part_switch(part, part_efx_addr, efx_parts, 'EFX') end
apply_eq_part = function(part) return apply_part_switch(part, part_eq_addr, eq_parts, 'EQ') end

-- Relabel an existing run, e.g. to Custom once a parameter is edited by hand.
relabel_run = function(take, base, text)
  delete_label_at(take, base)
  put_label(take, base, text)
end

-- Walk a preset in write order: the macro selector first, then every parameter
-- the preset supplies, skipping the macro entry itself. `emit(i, addr, value)`
-- gets each one with its position in the run, and returns false to abort.
-- Both the item and the live path drive this same walk, so the order and the
-- event count cannot drift apart between them. Blocks with no hardware macro
-- register (EQ) have entry.addr == nil, so no macro event is emitted.
local function each_preset_event(blk, entry, choice, emit)
  local preset = entry.macros[choice][2]
  local n = 0

  if entry.addr then
    local ok, err = emit(n, { 0x40, blk.addr_mid, entry.addr }, choice - 1)
    if not ok then return nil, err end
    n = n + 1
  end

  local i = 0
  for _, e in ipairs(blk[2]) do
    if not e.macros then
      i = i + 1
      if preset[i] then
        e.value = preset[i]
        local ok, err = emit(n, { 0x40, blk.addr_mid, e.addr }, preset[i])
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
    local ok, err = send_live(dt1({ 0x40, blk.addr_mid, e.addr, e.value }), take)
    if not ok then return false, err end
    return true, 'Sent ' .. e.name .. ' to hardware.'
  end

  reaper.Undo_BeginBlock()
  -- The run is laid out macro-first (when the block has a macro register --
  -- EQ does not, see each_preset_event), so this parameter's slot is its
  -- position among the non-macro entries. Same indexing as each_preset_event.
  local slot = entry.addr and 0 or -1
  for _, p in ipairs(blk[2]) do
    if not p.macros then
      slot = slot + 1
      if p == e then
        put_at(take, base + slot * cfg.tick_gap, { 0x40, blk.addr_mid, e.addr }, e.value)
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

-- The preset combo, +/-/Insert row shared by every FX_BLOCKS tab (Reverb,
-- Chorus, Delay on the Effects tab; EQ on its own tab). block_index is this
-- block's position in FX_BLOCKS, used to key saved presets.
local function fx_preset_row(blk, block_index, label_w, em)
  local macro_entry = blk[2][1]
  local presets = system_presets_for(blk, macro_entry, block_index)
  local selected = fx_preset_sel[blk[1]]
  ImGui.Text(ctx, 'Preset:')
  ImGui.SameLine(ctx, label_w)
  ImGui.SetNextItemWidth(ctx, em * 12)
  if ImGui.BeginCombo(ctx, '##systempreset' .. blk[1], selected.name) then
    for _, p in ipairs(presets) do
      if ImGui.Selectable(ctx, p.name, p == selected) then
        local ok, msg = system_preset_apply(blk, macro_entry, p)
        if ok then
          fx_preset_sel[blk[1]] = p
          set_status(("Loaded '%s' (values only; insert to send)." ):format(p.name))
        else set_status(msg) end
      end
    end
    ImGui.EndCombo(ctx)
  end
  local wheel = mouse_wheel_step()
  if wheel ~= 0 and #presets > 0 then
    local i = 1
    for n, p in ipairs(presets) do if p == selected then i = n end end
    local p = presets[clamp(i + wheel, 1, #presets)]
    local ok, msg = system_preset_apply(blk, macro_entry, p)
    if ok then fx_preset_sel[blk[1]] = p end
    set_status(ok and ("Loaded '%s' (values only; insert to send)." ):format(p.name) or msg)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, '+##systempresetadd' .. blk[1]) then
    efx_preset_name = ''
    preset_save_context = { kind = 'fx', blk = blk, entry = macro_entry, index = block_index }
    ImGui.OpenPopup(ctx, 'Save preset')
  end
  -- same hint the Insertion Effects tab gives, so the file is discoverable
  -- from whichever tab the preset is being saved on
  ImGui.SetItemTooltip(ctx, 'Save a preset to ' .. efx_presets_path())
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, '-##systempresetdelete' .. blk[1]) then
    if selected and not selected.built_in then
      for i, p in ipairs(efx_presets) do if p == selected then table.remove(efx_presets, i) break end end
      fx_preset_sel[blk[1]] = presets[1]
      if efx_presets_write(efx_presets) then set_status("Deleted '" .. selected.name .. "'.") end
    end
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Insert preset##systempresetinsert' .. blk[1]) then
    local _, msg = insert_system_preset(blk, macro_entry, selected)
    set_status(msg)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Insert only changes##systempresetchanges' .. blk[1]) then
    local _, msg = insert_system_preset_changes(blk, macro_entry, selected)
    set_status(msg)
  end
  draw_preset_popup(em)
end

-- Height the Effects tab asks for, measured like efx_window_h rather than
-- fixed: the tallest block (Delay, 10 parameters) has to fit without
-- scrolling, and the row count comes from fx_blocks.lua, so adding a
-- parameter there resizes the window instead of quietly clipping it.
local function fx_window_h(em)
  if fx_win_h then return fx_win_h end
  local rows = 0
  for _, blk in ipairs(FX_BLOCKS) do
    local n = 0
    for _, e in ipairs(blk[2]) do
      if not e.macros then n = n + 1 end
    end
    if n > rows then rows = n end
  end
  local row = ImGui.GetFrameHeightWithSpacing(ctx)
  -- Chrome above and below the parameter rows: the outer tab bar, the nested
  -- Reverb/Chorus/Delay tab bar, the preset row, the spacer under it, the
  -- footer separator and its row, plus the tab inset top and bottom. One
  -- spare row keeps the last parameter clear of the footer.
  fx_win_h = rows * row + row * 5 + em * 0.4 + TAB_PAD * 2 + em * 2
  -- Never come out shorter than the hand-tuned height this replaced: the
  -- measurement above is only as good as its guess at the chrome, and the
  -- old value was known to very nearly fit.
  if fx_win_h < 470 then fx_win_h = 470 end
  return fx_win_h
end

local function tab_effects()
  local em = ImGui.GetFontSize(ctx)
  if ImGui.BeginTabBar(ctx, 'fxtabs') then
    for block_index, blk in ipairs(FX_BLOCKS) do
      if blk[1] ~= 'EQ' and ImGui.BeginTabItem(ctx, blk[1]) then
        ImGui.Dummy(ctx, 0, em * 0.4)
        local label_w = ImGui.CalcTextSize(ctx, 'Time Ratio Right') + em
        fx_preset_row(blk, block_index, label_w, em)

        for _, e in ipairs(blk[2]) do
          if not e.macros then param_row(e, label_w, em * EFX_FIELD_W_EM) end
        end
        ImGui.EndTabItem(ctx)
      end
    end
    ImGui.EndTabBar(ctx)
  end
end

-- EQ tab ----------------------------------------------------------------

-- The global EQ block and its index in FX_BLOCKS, found by name rather than
-- assumed, so reordering FX_BLOCKS cannot silently point this at the wrong
-- block.
local EQ_BLOCK, EQ_BLOCK_INDEX
for i, blk in ipairs(FX_BLOCKS) do
  if blk[1] == 'EQ' then EQ_BLOCK, EQ_BLOCK_INDEX = blk, i end
end
assert(EQ_BLOCK, 'fx_blocks.lua must define an EQ block')

-- addr picks out one entry from EQ_BLOCK[2] by its sysex address (0x00-0x03)
-- rather than a hardcoded index, so the draw stays correct if the table order
-- ever changes.
local function eq_entry(addr)
  for _, e in ipairs(EQ_BLOCK[2]) do
    if e.addr == addr then return e end
  end
end

-- Packed 0xRRGGBBAA, same layout as theme.lua's local rgba() (not exported).
local function rgba(r, g, b, a) return (r << 24) | (g << 16) | (b << 8) | a end

local EQ_CURVE_RED    = rgba(220, 70, 70, 255)
local EQ_CURVE_LINE   = rgba(190, 190, 190, 255)
local EQ_CURVE_GRID   = rgba(75, 75, 75, 255)
local EQ_CURVE_BORDER = rgba(141, 141, 141, 255)
local EQ_CURVE_BG     = rgba(0, 0, 0, 255)
local EQ_LOW_HZ       = { [0] = 200, [1] = 400 }
local EQ_HIGH_HZ      = { [0] = 3000, [1] = 6000 }
local EQ_MIN_HZ       = 20
local EQ_MAX_HZ       = 20000

-- A rough preview of the shelf response: flat at the shelf gain below/above
-- each corner frequency, ramping through 0 dB in between. The SC-8850 gives
-- no in-between corner frequencies to interpolate from, so this is a shape
-- to eyeball the two shelves against each other, not a DSP-accurate curve.
local function eq_curve_preview(em)
  local low_freq, low_gain = eq_entry(0x00), eq_entry(0x01)
  local high_freq, high_gain = eq_entry(0x02), eq_entry(0x03)

  local h = em * 5
  -- A zero-width Dummy creates a one-pixel preview: all x coordinates then
  -- collapse onto the left border. The tab cursor already includes the left
  -- TAB_PAD inset; reserve the same space on the right as well.
  local w = math.max(0, ImGui.GetContentRegionAvail(ctx) - TAB_PAD)
  ImGui.Dummy(ctx, w, h)
  local x0, y0 = ImGui.GetItemRectMin(ctx)
  local x1, y1 = ImGui.GetItemRectMax(ctx)
  local draw_list = ImGui.GetWindowDrawList(ctx)

  ImGui.DrawList_AddRectFilled(draw_list, x0, y0, x1, y1, EQ_CURVE_BG)
  ImGui.DrawList_AddRect(draw_list, x0, y0, x1, y1, EQ_CURVE_BORDER)

  -- Place the corner markers on a logarithmic 20 Hz-20 kHz axis. This keeps
  -- the visual positions faithful to the frequency values: 200 Hz is around
  -- one third of the graph, while 3 kHz is farther right than two thirds.
  local function frequency_x(freq)
    local ratio = math.log(freq / EQ_MIN_HZ) / math.log(EQ_MAX_HZ / EQ_MIN_HZ)
    return x0 + math.max(0, math.min(1, ratio)) * (x1 - x0)
  end
  local low_x = frequency_x(EQ_LOW_HZ[low_freq.value] or EQ_LOW_HZ[0])
  local high_x = frequency_x(EQ_HIGH_HZ[high_freq.value] or EQ_HIGH_HZ[0])
  local low_label = low_freq.enum[low_freq.value + 1]
  local high_label = high_freq.enum[high_freq.value + 1]
  ImGui.DrawList_AddLine(draw_list, low_x, y0, low_x, y1, EQ_CURVE_GRID)
  ImGui.DrawList_AddLine(draw_list, high_x, y0, high_x, y1, EQ_CURVE_GRID)
  ImGui.DrawList_AddText(draw_list, low_x + 4, y0 + 2, EQ_CURVE_RED, low_label)
  ImGui.DrawList_AddText(draw_list, high_x + 4, y0 + 2, EQ_CURVE_RED, high_label)

  -- Map a gain byte (52-76, 64 = 0 dB) to a y within the box, then draw the
  -- shelf-flat / ramp / shelf-flat path. The slider's own min/max keeps the
  -- byte inside +/-12 dB, so the full range lands within the box height.
  local mid_y = (y0 + y1) / 2
  local half_h = (y1 - y0) / 2 - em * 0.5
  local function gain_y(v) return mid_y - (v - 64) / 12 * half_h end

  local low_y, mid_y_pt, high_y = gain_y(low_gain.value), mid_y, gain_y(high_gain.value)
  ImGui.DrawList_PathClear(draw_list)
  ImGui.DrawList_PathLineTo(draw_list, x0, low_y)
  ImGui.DrawList_PathLineTo(draw_list, low_x, low_y)
  local mid_x = (low_x + high_x) / 2
  local bend = (mid_x - low_x) * 0.45
  ImGui.DrawList_PathBezierCubicCurveTo(draw_list,
    low_x + bend, low_y,
    mid_x - bend, mid_y_pt,
    mid_x, mid_y_pt, 16)
  ImGui.DrawList_PathBezierCubicCurveTo(draw_list,
    mid_x + bend, mid_y_pt,
    high_x - bend, high_y,
    high_x, high_y, 16)
  ImGui.DrawList_PathLineTo(draw_list, x1, high_y)
  ImGui.DrawList_PathStroke(draw_list, EQ_CURVE_LINE, ImGui.DrawFlags_None, 2.0)
end

local function tab_eq()
  local em = ImGui.GetFontSize(ctx)
  local label_w = ImGui.CalcTextSize(ctx, 'EQ High Freq') + em
  fx_preset_row(EQ_BLOCK, EQ_BLOCK_INDEX, label_w, em)

  for _, e in ipairs(EQ_BLOCK[2]) do
    if not e.macros then param_row(e, label_w, em * EFX_FIELD_W_EM) end
  end

  ImGui.Dummy(ctx, 0, em * 0.5)
  eq_curve_preview(em)

  ImGui.Dummy(ctx, 0, em * 0.5)
  ImGui.Text(ctx, 'Parts using EQ:')
  for i = 1, 16 do
    if i > 1 then ImGui.SameLine(ctx) end
    local changed
    changed, eq_parts[i] = ImGui.Checkbox(ctx, ('%d##eqpart%d'):format(i, i), eq_parts[i])
    if changed then
      local _, msg = apply_eq_part(i)
      set_status(msg)
    end
  end
end

-- window: tabs, footer and the frame loop -----------------------------------

-- { label, draw function, height }. Height is the window height the tab asks
-- for when selected, and defaults to WIN_H. It may be a function, since
-- measuring text needs a live context and this table is built before there is
-- one. Width is not per-tab: every tab uses window_w.
local TABS = {
  { 'Master', tab_master },
  { 'EQ', tab_eq, 430 },
  { 'Insertion Effects', tab_insertion, efx_window_h },
  { 'Effects', tab_effects, fx_window_h },
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
  Theme.push(ctx, ImGui)
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
  Theme.pop(ctx, ImGui)

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
