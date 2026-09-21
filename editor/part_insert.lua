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
local D = require 'drum_params'
local DM = require 'drum_messages'

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
local PC_STATUS = 0xC0

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

-- Every tick already occupied by an event in this take.
--
-- Returned as a set so a search can ask about one tick at a time. Notes are
-- deliberately not counted: a parameter change sitting on the same tick as a
-- note is normal and wanted -- it is what makes the note sound that way.
local function occupied_ticks(take, R)
  local used = {}

  for i = 0, count_cc(take, R) - 1 do
    local ok, _, _, ppq = R.MIDI_GetCC(take, i)
    if ok then used[tick_of(ppq)] = true end
  end

  for i = 0, count_sysex(take, R) - 1 do
    local ok, _, _, ppq = R.MIDI_GetTextSysexEvt(take, i, false, false, 0, 0, '')
    if ok then used[tick_of(ppq)] = true end
  end

  return used
end

-- The first tick at or after `base` where a run of `count` events, spaced
-- `gap` apart, lands on nothing that is already there.
--
-- Two different parameters inserted at one cursor would otherwise stack on
-- the same tick. That is not merely untidy: the SC-8850 reads messages in
-- the order they arrive, and two SysEx writes at one instant leave the order
-- to whatever the sort happened to do -- so the value that wins is not the
-- one the user chose last.
--
-- Searching by whole runs rather than per message keeps a run contiguous,
-- which is what makes an RPN still readable as one gesture in the editor.
--
-- `mine` is the set of ticks this insert's OWN previous representation
-- occupies. Those are about to be removed, so they must not push the
-- replacement aside -- without this a re-edit would march further from the
-- cursor every time.
local function free_slot(used, base, count, gap, mine)
  local at = base
  -- A bounded search: past this many attempts the take is pathological and
  -- stacking is better than hanging the UI.
  for _ = 1, 4096 do
    local clear = true
    for i = 0, count - 1 do
      local tick = at + i * gap
      if used[tick] and not (mine and mine[tick]) then
        clear = false
        break
      end
    end
    if clear then return at end
    at = at + gap
  end
  return at
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
  if p.native == P.CC then
    -- Mono/Poly occupies two controllers; see its row in part_params.lua.
    local set = { [p.cc] = true }
    if p.cc_alt then set[p.cc_alt] = true end
    return set
  end
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
  if p.dt1_block == 'switch' then return GS.part_addr(part, p.dt1) end
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

-- The ticks one parameter's existing representation occupies on one Part.
--
-- Mirrors what remove_existing matches, because these are exactly the events
-- that are about to be deleted: a replacement must be free to reuse their
-- ticks rather than being pushed past its own old copy.
function M:_own_ticks(take, p, part)
  local R = self.reaper
  local channel = part - 1
  local mine = {}

  local wanted = native_controllers(p)
  if next(wanted) then
    for i = 0, count_cc(take, R) - 1 do
      local ok, _, _, ppq, chanmsg, chan, msg2 = R.MIDI_GetCC(take, i)
      if ok and chanmsg == CC_STATUS and chan == channel and wanted[msg2] then
        mine[tick_of(ppq)] = true
      end
    end
  end

  local addr = sysex_addr(p, part)
  for i = 0, count_sysex(take, R) - 1 do
    local ok, _, _, ppq, typ, msg =
      R.MIDI_GetTextSysexEvt(take, i, false, false, 0, 0, '')
    if ok and type(msg) == 'string' then
      if typ == SYSEX and addr and GS.dt1_addr_of(msg) == addr then
        mine[tick_of(ppq)] = true
      elseif typ == LABEL and msg:sub(1, #label_prefix(p, part))
                              == label_prefix(p, part) then
        mine[tick_of(ppq)] = true
      end
    end
  end

  return mine
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
  elseif event.kind == 'pc' then
    -- Written through MIDI_InsertCC, whose `chanmsg` is the status nibble
    -- rather than a fixed 0xB0 -- so 0xC0 makes a Program Change. That is
    -- what puts it in REAPER's own Bank/Program Select lane, which displays
    -- CC0, CC32 and the PC together as one entry. MIDI_InsertEvt would write
    -- the same bytes as an untyped raw event, which that lane does not show.
    --
    -- A PC carries one data byte, so msg3 is 0.
    R.MIDI_InsertCC(take, false, false, ppq, PC_STATUS, event.channel,
                    event.program & 0x7F, 0)
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
  local cursor = tick_of(self:cursor_ppq(take))
  local gap = self:gap(take)

  -- Two spans, deliberately different.
  --
  -- The write span is what this insertion will occupy: one tick per event.
  --
  -- The removal span is what the parameter's widest possible representation
  -- could occupy, whichever encoding wrote it. They differ exactly when the
  -- encoding changed -- replacing a five-message RPN run with a single DT1
  -- write must still clear all five.
  -- Where this insert's own previous representation sits, if any. It is
  -- about to be removed, so it must not push the replacement aside.
  local own_last = cursor + math.max(#events - 1, span_gaps(p)) * gap

  -- Slide off any tick another event already holds. Two parameters inserted
  -- at one cursor would otherwise stack, and the SC-8850 acts on messages in
  -- arrival order -- so which one wins would be down to the sort.
  local base = free_slot(occupied_ticks(take, R), cursor, #events, gap,
                         self:_own_ticks(take, p, part))

  local write_last = base + (#events - 1) * gap
  local remove_last = base + math.max(#events - 1, span_gaps(p)) * gap

  -- One undo point for the whole operation, removal included. Undoing an
  -- Insert that replaced a previous value must restore that previous value,
  -- which only happens if both halves are inside the same block.
  R.Undo_BeginBlock()

  local written, err = pcall(function()
    -- Removal spans the cursor as well as the new position: the previous
    -- copy was written at the cursor, and the new one may have slid past it.
    self:remove_existing(take, id, part, math.min(cursor, base),
                         math.max(own_last, remove_last))
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

-- drum controls -------------------------------------------------------------------

-- A drum control is identified by (map, note, parameter) and by nothing else.
-- No Part appears in it: the two drum maps are shared, every Part playing a
-- map hears the same per-note values, and a Part is only ever a way to reach
-- one (manual p.55).
--
-- That also makes a drum insert simpler than a Part insert in one respect and
-- stricter in another. Simpler, because there is exactly one encoding -- DT1
-- -- so there is no second representation to hunt for and `Use SysEx?` does
-- not reach these controls at all. Stricter, because the complete three-byte
-- address is the ONLY thing that distinguishes one drum event from another:
-- DRUM 1 and DRUM 2 differ in one nibble, two notes differ in one byte, and a
-- match on anything less would delete a neighbour and look like it worked.

-- The readable text written beside a drum insert, for example
-- "Drum 1 Note 60 Level 100". Map and note are both in it because the SysEx
-- bytes alone do not say which instrument on which map was edited, and one
-- take can hold edits for every note of both maps.
local DRUM_LABEL_PREFIX = 'Drum'

-- Everything up to and including the parameter name: the prefix that
-- identifies one control's label on one note of one map, without its value.
--
-- Narrow on purpose. "Drum 1 Note 60 Level " matches no other note, no other
-- map, no other parameter, and nothing the Part paths or the Effects Editor
-- write -- their labels start "Part " or with the Effects Editor's own text.
local function drum_label_prefix(mode, note, p)
  return ('%s %d Note %d %s '):format(DRUM_LABEL_PREFIX, mode, note, p.name)
end

function M.drum_label_text(mode, note, p, shown)
  return drum_label_prefix(mode, note, p) .. tostring(shown)
end

-- The ticks this control's existing representation occupies on this map and
-- note: its own SysEx event and its own label.
--
-- Mirrors what the removal below matches, because these are exactly the
-- events about to be deleted -- a replacement must be free to reuse their
-- ticks rather than being pushed past its own old copy.
function M:_own_drum_ticks(take, mode, note, p, addr)
  local R = self.reaper
  local prefix = drum_label_prefix(mode, note, p)
  local mine = {}

  for i = 0, count_sysex(take, R) - 1 do
    local ok, _, _, ppq, typ, msg =
      R.MIDI_GetTextSysexEvt(take, i, false, false, 0, 0, '')
    if ok and type(msg) == 'string' then
      if typ == SYSEX then
        local at = GS.dt1_addr_of(msg)
        if at and at[1] == addr[1] and at[2] == addr[2] and at[3] == addr[3] then
          mine[tick_of(ppq)] = true
        end
      elseif typ == LABEL and msg:sub(1, #prefix) == prefix then
        mine[tick_of(ppq)] = true
      end
    end
  end

  return mine
end

-- Remove this control's own event and own label within the span.
--
-- The SysEx match is the COMPLETE address, compared byte by byte -- never
-- Lua table identity, which would be false for two tables holding the same
-- three numbers and would silently never match anything.
--
-- Iterates backwards so deleting does not shift the indices still to visit.
function M:_remove_drum(take, mode, note, p, addr, first, last)
  local R = self.reaper
  local prefix = drum_label_prefix(mode, note, p)
  local removed = 0

  for i = count_sysex(take, R) - 1, 0, -1 do
    local ok, _, _, ppq, typ, msg =
      R.MIDI_GetTextSysexEvt(take, i, false, false, 0, 0, '')
    if ok and type(msg) == 'string' then
      local tick = tick_of(ppq)
      if tick >= first and tick <= last then
        local mine = false
        if typ == SYSEX then
          local at = GS.dt1_addr_of(msg)
          mine = at ~= nil and at[1] == addr[1] and at[2] == addr[2]
                 and at[3] == addr[3]
        elseif typ == LABEL then
          mine = msg:sub(1, #prefix) == prefix
        end
        if mine then
          R.MIDI_DeleteTextSysexEvt(take, i)
          removed = removed + 1
        end
      end
    end
  end

  return removed
end

-- Write one drum control's settled canonical value at the edit cursor.
--
--   mode   1 or 2 -- WHICH MAP, never a Part number
--   note   the MIDI note number, 0..127
--   id     a drum_params row id
--   value  the canonical value
--   shown  the value as the panel displays it, for the readable label.
--          Optional: nil writes no label.
--
-- Returns true, or false plus a message. A failure leaves the take as it
-- found it and the caller keeps its pending snapshot so the user can fix the
-- context and retry.
function M:insert_drum(take, mode, note, id, value, shown)
  if not take then return false, 'No MIDI take: open a MIDI editor.' end

  local p = D.BY_ID[id]
  if not p then return false, 'Unknown drum parameter: ' .. tostring(id) end
  if not D.valid_mode(mode) then
    return false, 'Drum map must be 1 or 2, got ' .. tostring(mode)
  end
  if not D.valid_note(note) then
    return false, 'Drum note must be an integer 0..127, got ' .. tostring(note)
  end

  -- Encoding validates the value and rejects rather than masking it, so a
  -- bad value fails here instead of becoming a real write to a real address.
  local ok, events = pcall(DM.encode, id, value, mode, note)
  if not ok then return false, tostring(events) end
  if #events == 0 then return false, 'Nothing to insert for ' .. p.name end

  local R = self.reaper
  local cursor = tick_of(self:cursor_ppq(take))
  local gap = self:gap(take)

  -- One event, so the span is one tick wide. There is no run here and no
  -- second encoding whose old representation could be longer than the new
  -- one -- the two spans a Part insert has to keep apart are the same span.
  local addr = events[1].addr
  local own = self:_own_drum_ticks(take, mode, note, p, addr)

  -- Slide off any tick another event already holds. Two SysEx writes at one
  -- instant leave their arrival order to the sort, so the value that wins
  -- would not be the one the user chose last. This control's OWN previous
  -- copy is exempt: it is about to be removed, and without that exemption a
  -- re-edit would march further from the cursor every time.
  local base = free_slot(occupied_ticks(take, R), cursor, #events, gap, own)
  local last = base + (#events - 1) * gap

  -- One undo point for the whole operation, removal included. Undoing an
  -- Insert that replaced a previous value must restore that previous value,
  -- which only happens if both halves are inside the same block.
  R.Undo_BeginBlock()

  local written, err = pcall(function()
    -- The span covers the cursor as well as the new position: the previous
    -- copy was written at the cursor, and the new one may have slid past it.
    self:_remove_drum(take, mode, note, p, addr,
                      math.min(cursor, base), math.max(cursor, last))
    for i, event in ipairs(events) do
      self:_write(take, event, base + (i - 1) * gap)
    end
    if shown then
      R.MIDI_InsertTextSysexEvt(take, false, false, base, LABEL,
                                M.drum_label_text(mode, note, p, shown))
    end
    -- Sorted once, after removal and insertion are both complete. Sorting in
    -- between would invalidate the indices the removal walk is holding.
    R.MIDI_Sort(take)
  end)

  local desc = ('Insert Drum %d %s'):format(mode, p.name)
  -- The block is closed on the failure path too, or REAPER is left with an
  -- open undo block and the next unrelated edit joins it.
  R.Undo_EndBlock(desc, -1)
  if not written then return false, tostring(err) end
  return true
end

-- voices -------------------------------------------------------------------------

-- The label written beside a voice insert, for example
-- "Part 10 Voice Piano 1". Shares the Part prefix with every parameter
-- label, so one take's PAGER writes all read alike.
local function voice_label_prefix(part)
  return ('%s %d Voice '):format(LABEL_PREFIX, part)
end

function M.voice_label_text(part, shown)
  return voice_label_prefix(part) .. shown
end

-- Remove a previous voice selection for one Part in the span.
--
-- Three things go: the two Bank Select controllers, the Program Change, and
-- the readable label. A voice is not a part_params row, so none of the
-- parameter removal paths match it -- they key off a row's controller
-- numbers and DT1 address, and a voice has neither.
function M:_remove_voice(take, part, first, last)
  local R = self.reaper
  local channel = part - 1
  local removed = 0

  -- The three messages of a voice selection: Bank Select MSB and LSB, and
  -- the Program Change. All three are CC events -- the PC carries a 0xC0
  -- status rather than 0xB0 -- so one walk finds them all.
  --
  -- Walked backwards because deleting shifts every later index down.
  for i = count_cc(take, R) - 1, 0, -1 do
    local ok, _, _, ppq, chanmsg, chan, msg2 = R.MIDI_GetCC(take, i)
    local mine = ok and chan == channel
      and ((chanmsg == PC_STATUS)
        or (chanmsg == CC_STATUS
            and (msg2 == PM.CC_BANK_MSB or msg2 == PM.CC_BANK_LSB)))
    if mine then
      local tick = tick_of(ppq)
      if tick >= first and tick <= last then
        R.MIDI_DeleteCC(take, i)
        removed = removed + 1
      end
    end
  end

  -- The label.
  local prefix = voice_label_prefix(part)
  for i = count_sysex(take, R) - 1, 0, -1 do
    local ok, _, _, ppq, typ, msg =
      R.MIDI_GetTextSysexEvt(take, i, false, false, 0, 0, '')
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

-- The ticks one Part's existing voice selection occupies.
--
-- The voice equivalent of _own_ticks: these events are about to be removed,
-- so a replacement may reuse their ticks instead of marching past its own
-- previous copy.
function M:_own_voice_ticks(take, part)
  local R = self.reaper
  local channel = part - 1
  local mine = {}

  for i = 0, count_cc(take, R) - 1 do
    local ok, _, _, ppq, chanmsg, chan, msg2 = R.MIDI_GetCC(take, i)
    if ok and chan == channel
       and ((chanmsg == PC_STATUS)
         or (chanmsg == CC_STATUS
             and (msg2 == PM.CC_BANK_MSB or msg2 == PM.CC_BANK_LSB))) then
      mine[tick_of(ppq)] = true
    end
  end

  local prefix = voice_label_prefix(part)
  for i = 0, count_sysex(take, R) - 1 do
    local ok, _, _, ppq, typ, msg =
      R.MIDI_GetTextSysexEvt(take, i, false, false, 0, 0, '')
    if ok and typ == LABEL and type(msg) == 'string'
       and msg:sub(1, #prefix) == prefix then
      mine[tick_of(ppq)] = true
    end
  end

  return mine
end

-- Write a voice selection at the edit cursor.
--
--   part   1..16; also selects the MIDI channel
--   msb    Bank Select MSB
--   lsb    Bank Select LSB, which is the instrument map
--   pc     the program number
--   shown  the voice name, for the readable label. Optional.
--
-- Three messages, one tick apart, in the order the hardware needs: the
-- Program Change must arrive after both bank bytes or it selects out of
-- whichever bank was last set.
--
-- Returns true, or false plus a message, leaving the take as it found it.
function M:insert_voice(take, part, msb, lsb, pc, shown)
  if not take then return false, 'No MIDI take: open a MIDI editor.' end

  local ok, events = pcall(PM.voice_events, part, msb, lsb, pc)
  if not ok then return false, tostring(events) end

  local R = self.reaper
  local cursor = tick_of(self:cursor_ppq(take))
  local gap = self:gap(take)
  local own_last = cursor + (#events - 1) * gap

  local base = free_slot(occupied_ticks(take, R), cursor, #events, gap,
                         self:_own_voice_ticks(take, part))
  local last = base + (#events - 1) * gap

  R.Undo_BeginBlock()

  local written, err = pcall(function()
    self:_remove_voice(take, part, math.min(cursor, base),
                       math.max(own_last, last))
    for i, event in ipairs(events) do
      self:_write(take, event, base + (i - 1) * gap)
    end
    if shown then
      R.MIDI_InsertTextSysexEvt(take, false, false, base, LABEL,
                                M.voice_label_text(part, shown))
    end
    R.MIDI_Sort(take)
  end)

  if not written then
    R.Undo_EndBlock('Insert Voice', -1)
    return false, tostring(err)
  end

  R.Undo_EndBlock('Insert Voice', -1)
  return true
end

M.CC_STATUS, M.PC_STATUS, M.SYSEX, M.LABEL =
  CC_STATUS, PC_STATUS, SYSEX, LABEL
M.REFERENCE_PPQ = REFERENCE_PPQ

return M
