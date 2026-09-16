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

-- Resolve the device a take's track sends to. Captured once when a batch is
-- queued and stored on every message, so changing the selected take mid-batch
-- cannot redirect the messages still waiting.
function M:resolve(take)
  if not take then return nil, NO_TAKE end
  local track = self.reaper.GetMediaItemTake_Track(take)
  if not track then return nil, NO_TAKE end
  local dev = M.decode_device(self.reaper.GetMediaTrackInfo_Value(track, 'I_MIDIHWOUT'))
  if not dev then return nil, NO_ROUTE end
  return dev
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
function M:_append(payloads, dev, class, addr)
  if #self.queue == 0 and not self.next_at then
    self.next_at = self:now()
  end
  for _, payload in ipairs(payloads) do
    self.queue[#self.queue + 1] =
      { payload = payload, dev = dev, class = class, addr = addr }
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

-- A settled parameter edit. It waits behind an active preset batch rather
-- than jumping it, so the run the user hears stays in order. A pending edit
-- to the same address is replaced in place: only the newest value matters,
-- and keeping the old position preserves the order edits were made in.
function M:preview_param(payload, take, addr)
  local dev, err = self:resolve(take)
  if not dev then return false, err end
  if addr then
    for _, m in ipairs(self.queue) do
      if m.class == PARAM and m.addr == addr then
        m.payload, m.dev = payload, dev
        return true
      end
    end
  end
  self:_append({ payload }, dev, PARAM, addr)
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
  self.reaper.SendMIDIMessageToHardware(m.dev, M.frame(m.payload))
  self.next_at = t + self.interval
  return true
end

M.NO_ROUTE, M.NO_TAKE = NO_ROUTE, NO_TAKE

return M
