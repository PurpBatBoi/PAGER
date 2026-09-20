-- Writing one Part parameter into the MIDI take, and replacing whatever
-- representation of it was already there.
--
-- Split out of part_editor.lua so it can be tested without ImGui: everything
-- here is REAPER calls and arithmetic, and none of it needs a window. The
-- editor owns the pending snapshot and decides WHEN to write; this module
-- owns WHAT lands in the take and what comes out first.
--
-- The input is the same typed event list part_messages.lua produces and
-- hardware_output.lua previews, which is what keeps preview and insertion
-- from drifting apart. There is no second encoding path here.
--
-- Two rules shape the whole file:
--
--   Replacement is targeted. Only an existing representation of the SAME
--   logical parameter, on the same channel, in the same cursor run is
--   removed. Unrelated CCs, RPNs, SysEx, notes and labels at that tick are
--   another tool's or another edit's, and survive untouched.
--
--   One Insert is one undo point. Removal and insertion happen inside a
--   single Undo block and the take is sorted once, after both.
--
-- Dependencies are injected through new(deps) so tests can drive a fake take;
-- in REAPER the editor passes the real reaper table.

local GS = require 'gs_sysex'
local P = require 'part_params'
local PM = require 'part_messages'

local M = {}
M.__index = M

-- The text/sysex lane carries two kinds of event. Type -1 is the SysEx the
-- hardware reads; type 1 is a generic text event, visible in REAPER's editor
-- and ignored by the device.
--
-- Only a SysEx event is ever a Part representation. A label is written
-- alongside one so the item says what it holds rather than showing an opaque
-- blob -- the Effects Editor has done this since it was written, and a Part
-- insert that skipped it would leave the take half-annotated.
local SYSEX, LABEL = -1, 1

-- Labels are matched by prefix rather than by exact text, because the value
-- is part of the label and changes between inserts. The prefix names the tool
-- and the parameter, which is enough to find this parameter's own label and
-- narrow enough not to touch the Effects Editor's.
local LABEL_PREFIX = 'Part'

-- Control Change, as MIDI_GetCC and MIDI_InsertCC report and expect it in
-- their chanmsg argument.
local CC_STATUS = 0xB0

-- The manual recommends separating adjacent control changes by about one tick
-- at 96 PPQ so a sequencer cannot reorder them at the same instant. Scaling
-- from the take's own resolution keeps that spacing musically identical at
-- 480 PPQ, where one tick would be far too tight.
local REFERENCE_PPQ = 96

-- deps.reaper : the reaper table
function M.new(deps)
  deps = deps or {}
  return setmetatable({ reaper = deps.reaper or reaper }, M)
end

-- geometry -------------------------------------------------------------------

-- PPQ is fractional, so every tick comparison rounds. A cursor a hair off
-- would otherwise never match an event sitting on the same tick.
local function tick_of(ppq)
  return math.floor(ppq + 0.5)
end

M.tick_of = tick_of

-- The take's own resolution, in ticks per quarter note. Asking for the
-- distance between two quarter notes is the documented way to get it -- there
-- is no direct accessor -- and a take that answers nonsense falls back to the
-- MIDI default rather than producing a zero gap.
function M:ppq_per_quarter(take)
  local R = self.reaper
  local ok, a = pcall(R.MIDI_GetPPQPosFromProjQN, take, 0)
  local ok2, b = pcall(R.MIDI_GetPPQPosFromProjQN, take, 1)
  if not ok or not ok2 or type(a) ~= 'number' or type(b) ~= 'number' then
    return 960
  end
  local span = b - a
  if not (span > 0) then return 960 end
  return span
end

-- The spacing between the events of one run, in ticks.
function M:gap(take)
  return math.max(1, math.floor(self:ppq_per_quarter(take) / REFERENCE_PPQ + 0.5))
end

-- The edit cursor as a tick in this take.
function M:cursor_ppq(take)
  return self.reaper.MIDI_GetPPQPosFromProjTime(take, self.reaper.GetCursorPosition())
end

-- reading the take ------------------------------------------------------------

local function count_cc(take, R)
  return select(3, R.MIDI_CountEvts(take))
end

local function count_sysex(take, R)
  return select(4, R.MIDI_CountEvts(take))
end

-- what a parameter looks like in a take ----------------------------------------

-- The controller numbers one row can occupy in its native form. For a plain
-- CC row that is its own controller; for an RPN row it is the whole ordered
-- run, selector and Data Entry and Null together, because those messages only
-- mean this parameter as a group.
--
-- Returned as a set, because matching walks the take once and asks "is this
-- controller one of mine" per event.
local function native_controllers(p)
  if p.native == P.CC then return { [p.cc] = true } end
  if p.native == P.RPN then
    local set = {
      [PM.CC_RPN_MSB] = true, [PM.CC_RPN_LSB] = true, [PM.CC_DATA_MSB] = true,
    }
    if p.rpn_fine then set[PM.CC_DATA_LSB] = true end
    return set
  end
  return {}
end

-- The DT1 addresses one row can occupy. A row has at most one, but Tuning
-- Offset and Fine Tune write two consecutive bytes from a single address, so
-- the address itself is still one value.
local function sysex_addr(p, part)
  if not P.has_sysex(p) then return nil end
  if p.dt1_block == 'bend' then return GS.part_bend_addr(part, p.dt1) end
  if p.dt1_block == 'switch' then return GS.part_eq_addr(part) end
  return GS.part_param_addr(part, p.dt1)
end

M.native_controllers, M.sysex_addr = native_controllers, sysex_addr

-- labels -------------------------------------------------------------------------

-- The readable text written beside a Part insert, for example
-- "Part 10 Cutoff +20". The channel is included because one take can hold
-- edits for all sixteen Parts and the SysEx bytes alone do not say which.
--
-- `shown` is the value as the panel displays it; the editor passes its own
-- formatting so the label and the footer cannot disagree.
function M.label_text(p, part, shown)
  return ('%s %d %s %s'):format(LABEL_PREFIX, part, p.name, shown)
end

-- The prefix that identifies one parameter's label on one Part, without its
-- value. Everything up to and including the parameter name.
local function label_prefix(p, part)
  return ('%s %d %s '):format(LABEL_PREFIX, part, p.name)
end

-- Remove this parameter's own label in the span.
--
-- Matched by prefix, so the value may differ from the one being replaced.
-- The Effects Editor's labels do not start with "Part <n> ", and another
-- parameter's label carries a different name, so neither is touched.
function M:_remove_label(take, p, part, first, last)
  local R = self.reaper
  local prefix = label_prefix(p, part)
  local removed = 0
  for i = count_sysex(take, R) - 1, 0, -1 do
    local ok, _, _, ppq, typ, msg = R.MIDI_GetTextSysexEvt(take, i, false, false, 0, 0, '')
    if ok and typ == LABEL and type(msg) == 'string'
       and msg:sub(1, #prefix) == prefix then
      local tick = tick_of(ppq)
      if tick >= first and tick <= last then
        R.MIDI_DeleteTextSysexEvt(take, i)
        removed = removed + 1
      end
    end
  end
  return removed
end

-- removal ----------------------------------------------------------------------

-- Remove this parameter's native representation within the run's tick span.
--
-- Matching is by channel AND controller AND tick, all three. Channel alone
-- would delete another Part's edit; controller alone would delete an
-- automation lane the user drew; tick alone would delete everything at the
-- cursor. An RPN matches its whole ordered run across the span, which is why
-- the span is passed in rather than assumed to be a single tick.
--
-- Iterates backwards so deleting does not shift the indices still to visit.
function M:_remove_native(take, p, channel, first, last)
  local R = self.reaper
  local wanted = native_controllers(p)
  if not next(wanted) then return 0 end

  local removed = 0
  for i = count_cc(take, R) - 1, 0, -1 do
    local ok, _, _, ppq, chanmsg, chan, msg2 = R.MIDI_GetCC(take, i)
    if ok and chanmsg == CC_STATUS and chan == channel and wanted[msg2] then
      local tick = tick_of(ppq)
      if tick >= first and tick <= last then
        R.MIDI_DeleteCC(take, i)
        removed = removed + 1
      end
    end
  end
  return removed
end

-- Remove this parameter's SysEx representation within the span.
--
-- The match is the COMPLETE Part address, not merely "some SysEx on this
-- tick". Two Part parameters differ only in the third address byte, and the
-- Effects Editor's own writes share the same 40 block, so a looser match
-- would delete a neighbour's event and look like it worked.
function M:_remove_sysex(take, p, part, first, last)
  local addr = sysex_addr(p, part)
  if not addr then return 0 end

  local R = self.reaper
  local removed = 0
  for i = count_sysex(take, R) - 1, 0, -1 do
    local ok, _, _, ppq, typ, msg = R.MIDI_GetTextSysexEvt(take, i, false, false, 0, 0, '')
    if ok and typ == SYSEX then
      local tick = tick_of(ppq)
      if tick >= first and tick <= last then
        local at = GS.dt1_addr_of(msg)
        if at and at[1] == addr[1] and at[2] == addr[2] and at[3] == addr[3] then
          R.MIDI_DeleteTextSysexEvt(take, i)
          removed = removed + 1
        end
      end
    end
  end
  return removed
end

-- How many ticks a parameter's LONGEST representation occupies, counted in
-- gaps from the cursor.
--
-- Removal has to cover what the old representation occupied, which is not
-- what the new one is about to occupy. Replacing a five-message RPN run with
-- a single DT1 write would otherwise search one tick, delete the selector
-- sitting on it, and leave the remaining four messages stranded in the take.
--
-- So the span is the widest either encoding can be: the native form's event
-- count, since only RPN rows are runs and their SysEx form is always a single
-- write.
local function span_gaps(p)
  if p.native ~= P.RPN then return 0 end
  return p.rpn_fine and 5 or 4
end

M.span_gaps = span_gaps

-- Remove every representation of one logical parameter at this cursor, in
-- BOTH encodings.
--
-- Checking both is what makes `Use SysEx?` safe to change between inserts.
-- Re-inserting a parameter that was written as a CC and is now SysEx must
-- replace the CC rather than leave it behind, or the take would carry two
-- values for one control and the later one would not reliably win.
function M:remove_existing(take, id, part, first, last)
  local p = P.BY_ID[id]
  assert(p, 'unknown part parameter: ' .. tostring(id))
  return self:_remove_native(take, p, part - 1, first, last)
       + self:_remove_sysex(take, p, part, first, last)
       + self:_remove_label(take, p, part, first, last)
end

-- writing -----------------------------------------------------------------------

-- Write one typed event at a tick. Nothing is selected or muted: an inserted
-- event that arrived selected would join whatever the user selects next.
function M:_write(take, event, ppq)
  local R = self.reaper
  if event.kind == 'cc' then
    R.MIDI_InsertCC(take, false, false, ppq, CC_STATUS, event.channel,
                    event.cc, event.value)
  else
    R.MIDI_InsertTextSysexEvt(take, false, false, ppq, SYSEX, event.payload)
  end
end

-- insertion -----------------------------------------------------------------------

-- Write one parameter's settled canonical value at the edit cursor.
--
--   id         a part_params row id
--   value      the canonical value
--   part       1..16; also selects the MIDI channel
--   use_sysex  that channel's Use SysEx? setting, read now rather than when
--              the edit was made -- the design says a pending value is
--              encoded using the setting active when Insert is pressed
--   shown      the value as the panel displays it, used for the readable
--              label. Optional: nil writes no label, which is what the tests
--              of the raw event layout want.
--
-- Returns true, or false plus a message. A failure leaves the take as it
-- found it and the caller keeps its pending snapshot so the user can fix the
-- context and retry.
function M:insert(take, id, value, part, use_sysex, shown)
  if not take then return false, 'No MIDI take: open a MIDI editor.' end
  local p = P.BY_ID[id]
  if not p then return false, 'Unknown parameter: ' .. tostring(id) end

  local ok, events = pcall(PM.encode, id, value, part, use_sysex)
  if not ok then return false, tostring(events) end
  if #events == 0 then return false, 'Nothing to insert for ' .. p.name end

  local R = self.reaper
  local base = tick_of(self:cursor_ppq(take))
  local gap = self:gap(take)

  -- Two spans, deliberately different.
  --
  -- The write span is what this insertion will occupy: one tick per event.
  --
  -- The removal span is what the parameter's widest possible representation
  -- could occupy, whichever encoding wrote it. They differ exactly when the
  -- encoding changed -- replacing a five-message RPN run with a single DT1
  -- write must still clear all five.
  local write_last = base + (#events - 1) * gap
  local remove_last = base + math.max(#events - 1, span_gaps(p)) * gap

  -- One undo point for the whole operation, removal included. Undoing an
  -- Insert that replaced a previous value must restore that previous value,
  -- which only happens if both halves are inside the same block.
  R.Undo_BeginBlock()

  local written, err = pcall(function()
    self:remove_existing(take, id, part, base, remove_last)
    for i, event in ipairs(events) do
      self:_write(take, event, base + (i - 1) * gap)
    end
    -- One label per insert, on the first tick. A run gets one for the whole
    -- run rather than one per message: the run is a single parameter change,
    -- and six labels would say the same thing six times.
    if shown then
      R.MIDI_InsertTextSysexEvt(take, false, false, base, LABEL,
                                M.label_text(p, part, shown))
    end
    -- Sorted once, after removal and insertion are both complete. Sorting in
    -- between would invalidate the indices the removal walk is holding.
    R.MIDI_Sort(take)
  end)

  if not written then
    -- The block is closed on the failure path too, or REAPER is left with an
    -- open undo block and the next unrelated edit joins it.
    R.Undo_EndBlock('Insert ' .. p.name, -1)
    return false, tostring(err)
  end

  R.Undo_EndBlock('Insert ' .. p.name, -1)
  return true
end

M.CC_STATUS, M.SYSEX, M.LABEL = CC_STATUS, SYSEX, LABEL
M.REFERENCE_PPQ = REFERENCE_PPQ

return M
