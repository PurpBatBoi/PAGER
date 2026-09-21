-- PAGER - hardware preview queue.
--
-- Owns every message that goes straight to the hardware: route resolution,
-- device decoding, F0/F7 framing, the 20 ms clock, queue ordering, and the
-- status line each action reports. MIDI-take editing is not here; it stays in
-- effects_editor.lua. The two are independent by design -- a queued preview is
-- never converted into a take event, and a take event is never previewed as a
-- side effect of being written.
--
-- Why a wall clock rather than PPQ: SendMIDIMessageToHardware sends in
-- immediate mode and takes no position argument, so spacing a run can only be
-- done by holding messages back and releasing them on time. The editor calls
-- pump() once per frame and this module decides whether anything is due.
--
-- Dependencies are injected through new(deps) so the queue can be driven by a
-- fake clock in tests. In REAPER the editor passes the real reaper table.

local M = {}
M.__index = M

-- The hardware needs time to process one SysEx message before the next
-- arrives; back-to-back sends drop messages. 20 ms is the interval the plan
-- fixes for every batch.
M.INTERVAL = 0.020

-- Priority classes, lowest first. A batch is replaceable as a unit: a newer
-- preset selection discards whatever is left of an older one, while parameter
-- edits queued behind it survive. Resets clear everything.
local PRESET, PARAM = 'preset', 'param'

-- Event kinds. Until the Part Editor there was only one -- every message was
-- a Roland SysEx payload carried without F0/F7 and framed at the send
-- boundary. Part previews add raw channel messages, which must NOT be framed:
-- an F0 in front of a Control Change is a different message entirely.
--
-- The kind travels on the queue entry rather than being sniffed from the
-- bytes, because a payload's first byte is not a reliable discriminator and a
-- wrong guess is silent -- the hardware simply ignores what it cannot parse.
local SYSEX, CHANNEL = 'sysex', 'channel'

-- Build the raw bytes of one channel message. `channel` is zero-based, as the
-- status nibble wants it.
function M.channel_bytes(status, channel, data1, data2)
  local bytes = { (status & 0xF0) | (channel & 0x0F), data1 & 0x7F }
  if data2 then bytes[#bytes + 1] = data2 & 0x7F end
  return string.char(table.unpack(bytes))
end

-- One typed event, as part_messages.lua emits it, converted into the payload
-- and kind this queue stores. A Control Change is status 0xB0.
function M.encode_event(e)
  if e.kind == 'cc' then
    return M.channel_bytes(0xB0, e.channel, e.cc, e.value), CHANNEL
  end
  if e.kind == 'pc' then
    -- Program Change is a two-byte message: status and program, no second
    -- data byte. channel_bytes omits it when none is given.
    return M.channel_bytes(0xC0, e.channel, e.program), CHANNEL
  end
  return e.payload, SYSEX
end

-- construction --------------------------------------------------------------

-- deps.reaper : the reaper table (GetMediaItemTake_Track,
--               GetMediaTrackInfo_Value, SendMIDIMessageToHardware)
-- deps.now    : optional clock returning seconds; defaults to time_precise.
function M.new(deps)
  deps = deps or {}
  local R = deps.reaper or reaper
  local self = setmetatable({
    reaper = R,
    now = deps.now or function() return R.time_precise() end,
    interval = deps.interval or M.INTERVAL,
    queue = {},     -- pending { payload, dev, class, addr } in send order
    next_at = nil,  -- when the head of the queue may go out
  }, M)
  return self
end

-- routing --------------------------------------------------------------------

-- Decode a track's I_MIDIHWOUT. Per the API: <0 disables hardware output, the
-- low 5 bits select channels and the next 5 the device index. The mask matters
-- -- higher bits are not ours, and a bare shift would hand SendMIDIMessage-
-- ToHardware a device number that does not exist.
function M.decode_device(hwout)
  if not hwout or hwout < 0 then return nil end
  return (math.floor(hwout) >> 5) & 0x1F
end

local NO_ROUTE = 'No MIDI hardware output on this track.'
local NO_TAKE = 'No MIDI take: open a MIDI editor or select a MIDI item.'
local NO_TRACK = 'No track: select one with a MIDI hardware output.'

-- Resolve the device a track sends to.
--
-- A route is a property of the TRACK, not of the take: a take is only ever a
-- way to reach one. Previewing therefore needs no MIDI item at all, which is
-- what lets the Part Editor drive the hardware from a bare selected track.
function M:resolve_track(track)
  if not track then return nil, NO_TRACK end
  local dev = M.decode_device(self.reaper.GetMediaTrackInfo_Value(track, 'I_MIDIHWOUT'))
  if not dev then return nil, NO_ROUTE end
  return dev
end

-- Resolve the device a take's track sends to. Captured once when a batch is
-- queued and stored on every message, so changing the selected take mid-batch
-- cannot redirect the messages still waiting.
function M:resolve(take)
  if not take then return nil, NO_TAKE end
  local track = self.reaper.GetMediaItemTake_Track(take)
  if not track then return nil, NO_TAKE end
  return self:resolve_track(track)
end

-- queueing -------------------------------------------------------------------

-- Drop every pending message of one class, or all of them when class is nil.
function M:_drop(class)
  if not class then
    self.queue = {}
    return
  end
  local kept = {}
  for _, m in ipairs(self.queue) do
    if m.class ~= class then kept[#kept + 1] = m end
  end
  self.queue = kept
end

-- Put messages on the queue and start the clock if it is not already running.
-- The first message of an idle queue is due immediately; the rest follow at
-- one interval each, so a batch is paced but never delayed at its start.
--
-- `kind` defaults to SYSEX, which is what every caller before the Part Editor
-- sends and why those callers did not have to change. `run` marks the entries
-- of one ordered group so coalescing can leave them alone.
function M:_append(payloads, dev, class, addr, kind, run)
  if #self.queue == 0 and not self.next_at then
    self.next_at = self:now()
  end
  for _, payload in ipairs(payloads) do
    self.queue[#self.queue + 1] =
      { payload = payload, dev = dev, class = class, addr = addr,
        kind = kind or SYSEX, run = run }
  end
end

-- A type or preset selection: the complete state as one ordered batch.
-- Replaces the unsent remainder of an older selection, because the user has
-- moved on from it -- but leaves queued parameter edits alone, since those
-- were made after it and still represent what the user wants to hear.
function M:preview_batch(payloads, take)
  local dev, err = self:resolve(take)
  if not dev then return false, err end
  self:_drop(PRESET)
  self:_append(payloads, dev, PRESET)
  if #self.queue == 0 then self.next_at = nil end
  return true
end

-- Whether a queued message is the pending copy of one logical edit.
--
-- The identity of a pending edit is the PAIR (resolved device, logical key),
-- never the key alone. A track's hardware output selects which SC-8850 Part
-- Group the messages reach, so the same key on two devices names two
-- different physical destinations -- and replacing one with the other would
-- silently drop an edit the user made and heard nothing of.
--
-- The logical key itself is the caller's, and it has to carry everything that
-- makes the target distinct: a Part id for a Part control, and map, note and
-- parameter for a drum control. A bare parameter id made an edit on Part 2
-- discard an unsent edit to the same control on Part 1.
local function same_target(m, dev, addr)
  return m.class == PARAM and m.dev == dev and m.addr == addr
end

-- A settled parameter edit. It waits behind an active preset batch rather
-- than jumping it, so the run the user hears stays in order. A pending edit
-- to the same target is replaced in place: only the newest value matters,
-- and keeping the old position preserves the order edits were made in.
function M:preview_param(payload, take, addr)
  local dev, err = self:resolve(take)
  if not dev then return false, err end
  if addr then
    for _, m in ipairs(self.queue) do
      if same_target(m, dev, addr) and not m.run then
        m.payload = payload
        return true
      end
    end
  end
  self:_append({ payload }, dev, PARAM, addr)
  return true
end

-- Drop every pending parameter entry for one logical target, optionally only
-- the ones belonging to a multi-message run.
--
-- `dev` is part of the match, not a detail the caller folded into `addr`:
-- the queue already owns route resolution, so it is the only thing that
-- knows which device a key actually resolved to.
--
-- A run is replaced whole or not at all: rewriting one message of an RPN in
-- place would leave the selector of the old value in front of the Data Entry
-- of the new one.
function M:_drop_param(dev, addr, only_runs)
  local kept = {}
  for _, m in ipairs(self.queue) do
    local mine = same_target(m, dev, addr) and (not only_runs or m.run)
    if not mine then kept[#kept + 1] = m end
  end
  self.queue = kept
end

-- A settled Part edit, as the ordered typed event list part_messages.lua
-- produces. One logical parameter, one call -- whether that parameter encodes
-- to a single Control Change, a single DT1 write, or a six-message RPN run.
--
-- `addr` identifies the logical parameter, not a wire address, so the same
-- coalescing rule applies across encodings: a newer edit to the same control
-- replaces its unsent predecessor even when the user flipped `Use SysEx?`
-- between the two. It must name the whole target -- the Part for a Part
-- control, the map, note and parameter for a drum one -- because the queue
-- pairs it with the RESOLVED DEVICE and nothing else distinguishes two
-- pending edits. What is never done is coalescing INSIDE a run, or
-- reordering one -- an RPN whose Null arrives before its Data Entry writes
-- nothing, and the queue is the last place that ordering could be lost.
--
-- `route` names where the messages go. A take resolves through its track, as
-- every other preview does; a `{ track = t }` route resolves the track
-- directly, which is what lets a Part be auditioned with no MIDI item in the
-- project at all.
function M:preview_events(events, route, addr)
  local dev, err
  if type(route) == 'table' and route.track ~= nil then
    dev, err = self:resolve_track(route.track)
  else
    dev, err = self:resolve(route)
  end
  if not dev then return false, err end
  if #events == 0 then return true end

  local run = #events > 1

  -- Replace whatever this parameter already had pending, whichever shape it
  -- was. The two directions are not symmetric:
  --
  -- Replacing with a run clears everything pending for the parameter, run or
  -- single, and appends the new run at the end. Its length differs from
  -- whatever was there, so there is no position to preserve.
  --
  -- Replacing with a single message clears any pending run first -- a run
  -- cannot be partially rewritten -- and then rewrites a surviving single
  -- message in place, which keeps the position the user's earlier edit
  -- earned in the queue.
  if addr then
    self:_drop_param(dev, addr, not run)
    if not run then
      for _, m in ipairs(self.queue) do
        if same_target(m, dev, addr) then
          local payload, kind = M.encode_event(events[1])
          m.payload, m.kind = payload, kind
          return true
        end
      end
    end
  end

  for _, e in ipairs(events) do
    local payload, kind = M.encode_event(e)
    self:_append({ payload }, dev, PARAM, addr, kind, run or nil)
  end
  return true
end

-- A reset supersedes everything: whatever was queued describes a state the
-- reset is about to discard, so sending it first would be audible nonsense.
function M:reset(payload, take)
  local dev, err = self:resolve(take)
  if not dev then
    self:cancel()
    return false, err
  end
  self:cancel()
  self:_append({ payload }, dev, PRESET)
  return true
end

-- Drop everything pending. Used when a tool closes, when the project tab
-- changes, and ahead of a reset. Queued messages are never written anywhere.
function M:cancel()
  self.queue, self.next_at = {}, nil
end

function M:pending() return #self.queue end

-- sending ---------------------------------------------------------------------

-- SendMIDIMessageToHardware wants the framed message; the payloads everything
-- else passes around exclude F0/F7 because that is what the MIDI-take API
-- wants. Exactly one pair is added here, at the boundary.
function M.frame(payload)
  return string.char(0xF0) .. payload .. string.char(0xF7)
end

-- Release at most one due message. Called once per editor frame: one per
-- frame is enough because the interval is longer than a frame, and it keeps
-- a long batch from blocking the UI thread.
--
-- Returns true when a message went out. There is no acknowledgement from the
-- device -- this reports submission, not receipt.
function M:pump()
  local m = self.queue[1]
  if not m then
    self.next_at = nil
    return false
  end
  local t = self:now()
  if self.next_at and t < self.next_at then return false end
  table.remove(self.queue, 1)
  -- Framing is per kind. A SysEx payload is carried without F0/F7 everywhere
  -- else because that is what MIDI_InsertTextSysexEvt wants, and gets exactly
  -- one pair here; a channel message is already complete and must go out
  -- untouched.
  local msg = m.kind == CHANNEL and m.payload or M.frame(m.payload)
  self.reaper.SendMIDIMessageToHardware(m.dev, msg)
  self.next_at = t + self.interval
  return true
end

M.NO_ROUTE, M.NO_TAKE, M.NO_TRACK = NO_ROUTE, NO_TAKE, NO_TRACK
M.SYSEX, M.CHANNEL = SYSEX, CHANNEL
M.PRESET, M.PARAM = PRESET, PARAM

return M
