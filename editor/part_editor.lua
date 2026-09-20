-- PAGER - Part Editor
--
-- Edits one SC-8850 Part at a time. The Part is whichever channel the active
-- MIDI editor's piano roll is set to; the port group comes from the take's
-- track hardware output. There is no channel selector and no 16-column grid,
-- because REAPER already owns that choice and a second one would disagree
-- with it.
--
-- One fixed behaviour, not a mode. A settled slider or switch previews on the
-- hardware and touches nothing in the take. Insert writes the one pending
-- parameter at the edit cursor and sends nothing. The two halves are
-- independent, which is what makes a partial result reportable: a preview
-- that could not be routed still leaves a value that can be inserted.
--
-- The one-pending-snapshot rule is the centre of the design. Each channel
-- remembers exactly one touched parameter and its settled value. Touching
-- another parameter replaces it; pending edits never accumulate. That is what
-- keeps Insert unambiguous -- it writes one parameter, and the footer can
-- always name which.
--
-- Protocol lives elsewhere: part_params.lua holds the control metadata,
-- part_messages.lua turns a canonical value into ordered typed events, and
-- part_insert.lua writes them into the take. This file owns the panel, the
-- channel binding, the pending snapshot, session state and the launcher
-- lifecycle -- and no MIDI bytes at all.
--
-- Lua binds a local at closure creation, so a function must appear above its
-- callers or it resolves to a nil global at run time rather than at load.
-- The order below follows that: context, state, helpers, drawing, lifecycle.

if not reaper.ImGui_GetBuiltinPath then
  return reaper.MB('ReaImGui is not installed or too old.', 'PAGER - Part Editor', 0)
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path

-- Sibling modules. get_action_context returns the path the script was loaded
-- from, so this works wherever the folder is installed.
local SCRIPT_DIR = ({ reaper.get_action_context() })[2]:match('^(.*[/\\])') or ''
package.path = SCRIPT_DIR .. '?.lua;' .. SCRIPT_DIR .. '../lib/?.lua;' .. package.path

local ImGui = require 'imgui' '0.10'
local Theme = require 'theme'
local P = require 'part_params'
local PM = require 'part_messages'
local PartInsert = require 'part_insert'
local HardwareOutput = require 'hardware_output'
local SessionState = require 'session_state'

local TITLE = 'PAGER - Part Editor'

-- The ReaImGui context. Created on the first start() rather than at load, so
-- PAGER can require this module without putting a window on screen, and
-- recreated after a close so a returning visit draws into a live context.
local ctx

-- The hardware preview queue. Owns routing, framing, pacing and ordering;
-- nothing here sends directly.
local hw = HardwareOutput.new({ reaper = reaper })

-- Take insertion and targeted replacement.
local inserter = PartInsert.new({ reaper = reaper })

-- Per-project session state, under this tool's own key so the Effects
-- Editor's record is untouched.
local SESSION_TOOL = 'part_editor'
local session = SessionState.new({ reaper = reaper })
local bound_project

local FONT_SIZE = 14
local WIN_W, WIN_H = 640, 500
local STATUS_SECS = 6

local RESTORED_NOTICE = 'Restored values; not sent to hardware.'
local NO_EDITOR = 'No active MIDI editor: open one to choose a Part.'

-- per-channel state -----------------------------------------------------------

-- Sixteen independent channels, each holding its own control values and its
-- own Use SysEx? setting. Switching channel shows a different set; it sends
-- nothing and creates no pending edit.
--
-- `pending` is deliberately part of this table but NOT part of what is saved:
-- a pending snapshot is transient by design and must not survive closing the
-- tool or changing project tabs.
local channels = {}

local function blank_channel()
  local values = {}
  for _, p in ipairs(P.PARAMS) do values[p.id] = p.default end
  return { values = values, use_sysex = false, pending = nil }
end

local function reset_channels()
  channels = {}
  for i = 1, 16 do channels[i] = blank_channel() end
end

reset_channels()

-- status line -------------------------------------------------------------------

local status, status_time = '', 0

local function set_status(msg)
  status, status_time = msg or '', reaper.time_precise()
end

-- context: the active take and its Part -------------------------------------------

-- The MIDI editor owns both the take and the selected channel, so both come
-- from it or neither does. Returning nil for the editor is the disabled
-- state the whole panel keys off.
local function active_editor()
  local ed = reaper.MIDIEditor_GetActive()
  if not ed then return nil end
  local take = reaper.MIDIEditor_GetTake(ed)
  if not take then return nil end
  return ed, take
end

-- The visible Part, 1..16.
--
-- default_note_chan is zero-based, which is the piano roll's own channel
-- selector. A missing or out-of-range answer falls back to Part 1 rather than
-- indexing the channel table with nil.
local function active_part(ed)
  if not ed then return nil end
  local ok, chan = pcall(reaper.MIDIEditor_GetSetting_int, ed, 'default_note_chan')
  if not ok or type(chan) ~= 'number' then return 1 end
  chan = math.floor(chan) + 1
  if chan < 1 or chan > 16 then return 1 end
  return chan
end

-- display -------------------------------------------------------------------------

-- A canonical value as the panel shows it. The encoder never sees these
-- strings; they exist so the user reads musical units rather than bytes.
local function display_value(p, v)
  local rule = p.display
  if rule == 'signed' then return ('%+d'):format(v) end
  if rule == 'semi' then return ('%+d st'):format(v) end
  if rule == 'hz' then return ('%+.1f Hz'):format(v) end
  if rule == 'cents' then return ('%+.0f cents'):format(v) end
  if rule == 'switch' then return v >= 1 and 'On' or 'Off' end
  if rule == 'pan' then
    if v == 0 then return 'C' end
    if v < 0 then return ('L%d'):format(-v) end
    return ('R%d'):format(v)
  end
  return ('%d'):format(v)
end

-- The slider format string. ImGui substitutes the value into %d/%f itself,
-- so a rule that shows something other than the raw number has to pre-render
-- and escape any percent signs it produced.
local function slider_format(p, v)
  if p.display == 'plain' then return '%d' end
  return (display_value(p, v):gsub('%%', '%%%%'))
end

-- pending snapshot -------------------------------------------------------------------

-- Record the one parameter this channel has pending, replacing whatever was
-- there. Exactly one, by design: Insert writes one parameter and the footer
-- names it.
local function set_pending(part, id, value)
  channels[part].pending = { id = id, value = value }
end

local function pending_text(part)
  local pend = channels[part] and channels[part].pending
  if not pend then return '' end
  local p = P.BY_ID[pend.id]
  return ('Pending: %s %s'):format(p.name, display_value(p, pend.value))
end

-- preview -------------------------------------------------------------------------

-- Send one settled edit to the hardware. Never writes the take.
--
-- A routing failure is reported but does NOT discard the edit: the value
-- stays on screen and stays pending, so the user can fix the route or simply
-- insert it anyway.
local function preview(take, part, id, value)
  local ch = channels[part]
  local ok, events = pcall(PM.encode, id, value, part, ch.use_sysex)
  if not ok then return set_status('ERROR: ' .. tostring(events)) end

  local sent, err = hw:preview_events(events, take, id)
  if not sent then
    set_status(err .. ' Value kept and still insertable.')
  else
    set_status('')
  end
end

-- Handle one settled edit: it becomes this channel's sole pending snapshot
-- and previews on the hardware.
local function commit(take, part, id, value)
  set_pending(part, id, value)
  preview(take, part, id, value)
end

-- insert -------------------------------------------------------------------------

-- Write the current channel's pending parameter at the edit cursor.
--
-- A success clears the snapshot; a failure keeps it, so the user can correct
-- the context and retry. Nothing is previewed here -- Insert never sends a
-- second copy of what the user already heard.
local function insert_pending(take, part)
  local ch = channels[part]
  local pend = ch.pending
  if not pend then return set_status('Nothing pending to insert.') end

  -- The displayed value goes with it, so the readable text event in the take
  -- reads the same way the footer does rather than showing a raw byte.
  local p = P.BY_ID[pend.id]
  local ok, err = inserter:insert(take, pend.id, pend.value, part,
                                  ch.use_sysex, display_value(p, pend.value))
  if not ok then
    return set_status('Insert failed: ' .. tostring(err))
  end

  ch.pending = nil
  set_status(('Inserted %s %s'):format(p.name, display_value(p, pend.value)))
end

-- widgets -------------------------------------------------------------------------

-- Double-click reset state, per control. Kept outside the channel tables
-- because it describes a mouse gesture in progress, not a value worth saving.
local resetting = {}

-- Decide whether the control just drawn has settled, and apply the
-- double-click reset.
--
-- Two things have to be true at once. A slider reports a value every frame it
-- is dragged, but only the value it lands on is worth sending, so the send
-- waits for IsItemDeactivatedAfterEdit. And a double-click reset is not a
-- single event: the click has already dragged the value somewhere and the
-- button stays down afterwards, so the default is held over every frame until
-- release. Deactivation then fires on the release frame and counts the reset
-- as the value change it is, which is what makes a reset a manual touch.
--
-- Mirrors slider_settled in effects_editor.lua deliberately; the two tools
-- must feel identical under the mouse.
local function settled(p, part)
  local ch = channels[part]
  local send = ImGui.IsItemDeactivatedAfterEdit(ctx)
  if ImGui.IsItemHovered(ctx)
     and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
    resetting[p.id] = true
  end
  if resetting[p.id] then
    ch.values[p.id] = p.default
    if ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left) then
      send = false
    else
      resetting[p.id] = nil
    end
  end
  return send
end

-- One control row. Returns true on the frame its value settled.
local function control_row(p, part, label_w, field_w)
  local ch = channels[part]
  local v = ch.values[p.id]

  ImGui.Text(ctx, p.name)
  ImGui.SameLine(ctx, label_w)
  ImGui.SetNextItemWidth(ctx, field_w)

  if p.display == 'switch' then
    -- A switch has no settle to wait for: a checkbox commits on the click.
    local changed, on = ImGui.Checkbox(ctx, '##' .. p.id, v >= 1)
    if changed then
      ch.values[p.id] = on and 1 or 0
      return true
    end
    return false
  end

  local changed, nv
  if p.step and p.step < 1 then
    -- Tuning Offset is the one continuous control; everything else is whole
    -- numbers and reads better as an integer slider.
    changed, nv = ImGui.SliderDouble(ctx, '##' .. p.id, v, p.min, p.max,
                                     slider_format(p, v),
                                     ImGui.SliderFlags_ClampOnInput)
  else
    -- ClampOnInput: a value typed via Ctrl+Click is otherwise not clamped and
    -- can leave the parameter's documented range.
    changed, nv = ImGui.SliderInt(ctx, '##' .. p.id, math.floor(v),
                                  math.floor(p.min), math.floor(p.max),
                                  slider_format(p, v),
                                  ImGui.SliderFlags_ClampOnInput)
  end
  if changed then ch.values[p.id] = nv end

  return settled(p, part)
end

-- panel -------------------------------------------------------------------------

-- The two columns, by group. Ten control rows each, which is what makes the
-- window short enough not to scroll: stacked, the twenty rows and six headers
-- need about 720px, and side by side they need about half that.
--
-- Listed explicitly rather than split by counting, because the balance is a
-- layout decision -- Sends and Mix is five rows and Tuning is two, so an
-- even split by group COUNT would leave the columns visibly ragged.
local COLUMNS = {
  { 'Sends and Mix', 'Filter', 'Envelope' },
  { 'Tuning', 'Vibrato', 'Switches and Performance' },
}

-- Draw one column's groups. Returns nothing; commits happen as they settle.
--
-- `part` is nil when there is no MIDI editor. The controls are still drawn,
-- disabled, so the user can see what the tool offers and why it is
-- unavailable -- but every row needs SOME channel to read a value from, so
-- channel 1 stands in. Nothing can be committed in that state, because a
-- disabled widget never settles and `take` is nil anyway.
local function column(groups, take, part, label_w, field_w)
  local shown = part or 1
  for _, group in ipairs(groups) do
    ImGui.SeparatorText(ctx, group)
    for _, p in ipairs(P.PARAMS) do
      if p.group == group then
        if control_row(p, shown, label_w, field_w) and take and part then
          commit(take, part, p.id, channels[part].values[p.id])
        end
      end
    end
  end
end

-- Draw the grouped controls in two columns.
--
-- Each column is its own child so the separators and the slider widths stay
-- inside it: a SameLine-based split would let a long label in one column push
-- the other one's fields out of alignment.
local function panel(take, part, em)
  local label_w = em * 9
  local field_w = em * 8

  local avail = ImGui.GetContentRegionAvail(ctx)
  -- Half the space each, less the gap between them.
  local gap = select(1, ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing))
  local col_w = (avail - gap) / 2

  for i, groups in ipairs(COLUMNS) do
    if i > 1 then ImGui.SameLine(ctx) end
    -- ChildFlags_None: no ResizeX, so the divider is not a drag handle.
    -- false means collapsed or fully clipped, and the binding has already
    -- ended the child in that case -- so EndChild belongs inside the branch.
    if ImGui.BeginChild(ctx, 'col' .. i, col_w, 0, ImGui.ChildFlags_None) then
      column(groups, take, part, label_w, field_w)
      ImGui.EndChild(ctx)
    end
  end
end

-- footer -------------------------------------------------------------------------

-- Set by the footer button; read by the loop, which owns the one exit. A flag
-- rather than a direct call because closing has to happen between frames, not
-- in the middle of one still drawing into the context.
local want_close = false
local function request_close() want_close = true end

local function footer(take, part)
  ImGui.Separator(ctx)

  if ImGui.Button(ctx, 'Back to PAGER') then request_close() end

  ImGui.SameLine(ctx)
  local can_insert = take ~= nil and part ~= nil
                     and channels[part] and channels[part].pending ~= nil
  if not can_insert then ImGui.BeginDisabled(ctx, true) end
  if ImGui.Button(ctx, 'Insert') and can_insert then
    insert_pending(take, part)
  end
  if not can_insert then ImGui.EndDisabled(ctx) end

  if part then
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, pending_text(part))
  end

  -- Use SysEx? sits at the right end of the action row, beside the button it
  -- governs: it decides how the next preview and the next Insert are encoded,
  -- and changes nothing by itself.
  --
  -- Drawn whether or not there is an active Part. It is per-channel state
  -- like every slider above, so hiding it without a MIDI editor would make
  -- the one setting that changes how everything else is encoded the only
  -- control that disappears. Without a Part it shows channel 1, inert.
  ImGui.SameLine(ctx)
  local label = 'Use SysEx?'
  -- Right-align against the space this row has left: the checkbox box itself
  -- plus its label, plus the padding between them.
  local box_w = ImGui.GetFrameHeight(ctx)
              + select(1, ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemInnerSpacing))
              + ImGui.CalcTextSize(ctx, label)
  local avail = ImGui.GetContentRegionAvail(ctx)
  local x, y = ImGui.GetCursorPos(ctx)
  ImGui.SetCursorPos(ctx, x + math.max(0, avail - box_w), y)

  if not part then ImGui.BeginDisabled(ctx, true) end
  local changed, on = ImGui.Checkbox(ctx, label, channels[part or 1].use_sysex)
  if changed and part then channels[part].use_sysex = on end
  if not part then ImGui.EndDisabled(ctx) end

  if status ~= '' then
    ImGui.Text(ctx, status)
  end
end

-- session state -------------------------------------------------------------------

-- Only plain data crosses this boundary, and only what a reopened editor
-- should show: per-channel control values and per-channel Use SysEx?.
-- Pending snapshots are transient by contract and are deliberately absent.
local function capture_state()
  local out = {}
  for i = 1, 16 do
    local ch = channels[i]
    local values = {}
    for _, p in ipairs(P.PARAMS) do values[p.id] = ch.values[p.id] end
    out[tostring(i)] = { values = values, use_sysex = ch.use_sysex }
  end
  return { channels = out }
end

-- Apply a saved state. Passive by contract: this writes values into the
-- tables the UI draws from and queues nothing, so nothing reaches the
-- hardware until the user's next edit.
--
-- Every restored value goes through P.validate, which DROPS anything outside
-- the parameter's documented range rather than clamping it. A clamped value
-- looks deliberate on screen and the user cannot see which field came back
-- wrong. Unknown fields are ignored, for forward compatibility.
local function restore_state(st)
  if type(st) ~= 'table' or type(st.channels) ~= 'table' then return false end

  for i = 1, 16 do
    local saved = st.channels[tostring(i)]
    if type(saved) == 'table' then
      local ch = channels[i]
      if type(saved.use_sysex) == 'boolean' then ch.use_sysex = saved.use_sysex end
      if type(saved.values) == 'table' then
        for _, p in ipairs(P.PARAMS) do
          local v = P.validate(p, saved.values[p.id])
          if v ~= nil then ch.values[p.id] = v end
        end
      end
    end
  end
  return true
end

-- Save the current project's state, then load the project now active.
--
-- Both calls name their project explicitly. REAPER already reports `now`, but
-- the values still in these tables belong to `bound_project` -- letting either
-- call resolve the project itself would file the old project's values under
-- the new project's key and then read that same record back, which looks
-- exactly like a restore that changed nothing.
local function check_project()
  local now = session:project_key()
  if now == bound_project then return end

  session:save(SESSION_TOOL, capture_state(), bound_project)
  -- Queued previews describe the old project's hardware route; they must not
  -- play into the new one.
  hw:cancel()
  reset_channels()
  restore_state(session:load(SESSION_TOOL, now) or {})
  bound_project = now
  set_status(RESTORED_NOTICE)
end

-- frame loop -------------------------------------------------------------------------

local on_close_cb, closed
local finish
local first_frame = true

local function frame()
  local ed, take = active_editor()
  local part = active_part(ed)

  -- Header: which Part is being edited, or why none is. The encoding switch
  -- lives in the footer beside Insert, because that is the action it governs.
  ImGui.Text(ctx, part and ('Channel %d'):format(part) or NO_EDITOR)

  ImGui.Separator(ctx)

  local em = ImGui.GetFontSize(ctx)
  local footer_h = ImGui.GetFrameHeightWithSpacing(ctx) * 2
                 + select(2, ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing))

  -- Everything is drawn either way; without an editor it is simply inert, so
  -- the user can see what the tool offers and why it is unavailable.
  if not take then ImGui.BeginDisabled(ctx, true) end
  -- false means collapsed or fully clipped, and the binding has already ended
  -- the child in that case -- so EndChild belongs inside the branch.
  if ImGui.BeginChild(ctx, 'body', 0, -footer_h, ImGui.ChildFlags_None) then
    panel(take, part, em)
    ImGui.EndChild(ctx)
  end
  if not take then ImGui.EndDisabled(ctx) end

  footer(take, part)
end

local loop
loop = function()
  -- A frame can still be scheduled when the window has already gone: REAPER
  -- runs deferred callbacks one more time after the one that closed. Drawing
  -- into a released context is a crash, not an error, so this returns first.
  if not ctx then return end

  if status ~= '' and reaper.time_precise() - status_time > STATUS_SECS then
    status = ''
  end

  -- A project-tab change is only observable by asking, so it is checked once
  -- per frame before anything is drawn from the values it may replace.
  check_project()

  -- Release at most one due hardware message per frame. This is the only
  -- thing that moves the preview queue; nothing sends directly.
  hw:pump()

  Theme.begin_frame(ctx, ImGui, FONT_SIZE)
  if first_frame then
    ImGui.SetNextWindowSize(ctx, WIN_W, WIN_H, ImGui.Cond_Always)
    first_frame = false
  end
  local visible, open = ImGui.Begin(ctx, TITLE, true)
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

-- The single exit. Saves what the next visit restores, drops the hardware
-- queue, releases the context, and returns control to whoever started this
-- tool.
--
-- Order matters: state is captured before the context goes, because capture
-- reads the same tables the UI drew from, and the queue is cancelled rather
-- than flushed -- a preview the user never heard must not play into a window
-- that is no longer open.
finish = function()
  if closed then return end
  closed = true

  session:save(SESSION_TOOL, capture_state())
  hw:cancel()

  -- Releasing the context is dropping the last reference to it: ReaImGui has
  -- no DestroyContext and collects unattached objects left unused. The font is
  -- attached to this context and goes with it (theme.lua keys its cache
  -- weakly, so the entry is collected rather than pinning a dead context).
  ctx = nil

  local cb = on_close_cb
  on_close_cb = nil
  if cb then cb() end
end

-- Entry point. PAGER calls this; on_close is invoked once, when the window is
-- gone and its state has been saved.
--
-- Everything per-visit is reset here rather than at load, because the module
-- is required once and started many times: a second visit must not inherit
-- the first one's transient status line, close flag or pending snapshots.
local function start(on_close)
  on_close_cb, closed, want_close = on_close, false, false
  status, status_time = '', 0
  first_frame = true
  resetting = {}

  -- Pending snapshots do not survive a close, by design.
  reset_channels()

  ctx = ImGui.CreateContext(TITLE)
  -- native OS window frame instead of ImGui's drawn title bar, matching the
  -- other tools.
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, 0)

  -- Restore before the first frame draws, so the window opens showing the
  -- values it will keep rather than defaults that visibly change. Passive by
  -- contract: nothing is queued for the hardware here.
  bound_project = session:project_key()
  local saved = session:load(SESSION_TOOL)
  if saved and restore_state(saved) then set_status(RESTORED_NOTICE) end

  reaper.defer(loop)
end

-- Required by PAGER, which calls start(). Run directly as an action it still
-- opens on its own, with no launcher to return to.
local M = { start = start }

if not rawget(_G, 'PAGER_TOOL') then start(nil) end

return M
