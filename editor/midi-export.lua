-- Custom MIDI exporter
-- Requires ReaImGui 0.10+ and MIDIUtils from the sockmonkey72 ReaPack.

local DEFAULT_OUTPUT_PPQ = 960
local MAX_VLQ = 0x0FFFFFFF

-- MIDIUtils lives beside the user's other ReaPack scripts rather than next to
-- this file, so the resource path is the only reliable way to reach it.
-- Tests install their own MIDIUtils here; in REAPER this starts empty and the
-- real library is required on demand.
local MIDIUtils = rawget(_G, "MIDI_EXPORT_MIDIUTILS")
local function require_midiutils()
  if MIDIUtils then return MIDIUtils end
  package.path = reaper.GetResourcePath()
    .. "/Scripts/sockmonkey72 Scripts/MIDI/?.lua;" .. package.path
  local loaded, library = pcall(require, "MIDIUtils")
  if not loaded or type(library) ~= "table" then
    reaper.ShowMessageBox(
      "MIDIUtils was not found.\n\nInstall the sockmonkey72 MIDI scripts with"
        .. " ReaPack, then run this script again.",
      "PAGER - MIDI Export",
      0
    )
    error("MIDIUtils not available")
  end
  MIDIUtils = library
  -- Argument type-checking costs time on every call and buys nothing here: a
  -- wrong argument is our bug rather than user input to recover from.
  MIDIUtils.ENFORCE_ARGS = false
  return MIDIUtils
end

local function fail(message)
  reaper.ShowMessageBox(message, "PAGER - MIDI Export", 0)
  error(message)
end

local function u16(value)
  return string.char(math.floor(value / 256) % 256, value % 256)
end

local function u24(value)
  return string.char(
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256
  )
end

local function u32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256
  )
end

local function vlq(value)
  value = math.floor(value + 0.5)
  if value < 0 or value > MAX_VLQ then
    fail("MIDI delta-time is outside the Standard MIDI File VLQ range.")
  end

  local bytes = { value % 128 }
  value = math.floor(value / 128)
  while value > 0 do
    table.insert(bytes, 1, (value % 128) + 128)
    value = math.floor(value / 128)
  end
  return string.char(table.unpack(bytes))
end

local function byte_at(message, index)
  return message:byte(index)
end

local function is_ccbz(message)
  return byte_at(message, 1) == 0xFF
    and byte_at(message, 2) == 0x0F
    and message:sub(3, 7) == "CCBZ "
end

local function validate_channel_message(message)
  local status = byte_at(message, 1)
  if not status or status < 0x80 or status > 0xEF then
    fail(string.format("Unsupported MIDI status 0x%02X.", status or 0))
  end

  local kind = math.floor(status / 16)
  local expected = (kind == 0xC or kind == 0xD) and 2 or 3

  -- Program change and channel pressure carry one data byte, but REAPER
  -- stores them padded to three and MIDIUtils hands them back that way
  -- (CCEvent:GetMIDIString pads a two-byte message with a trailing zero).
  -- The pad is REAPER's buffer format, not part of the message: writing it
  -- into an SMF desynchronises every reader, which consumes the 00 as the
  -- next event's status and decodes the rest of the track as garbage.
  if #message > expected and byte_at(message, #message) == 0 then
    message = message:sub(1, expected)
  end

  if #message ~= expected then
    fail(string.format(
      "Channel message 0x%02X has %d bytes; expected %d.",
      status, #message, expected
    ))
  end

  for index = 2, #message do
    if byte_at(message, index) > 0x7F then
      fail("A MIDI channel data byte has its status bit set.")
    end
  end
  return message
end

local function read_vlq(message, position)
  local value = 0
  local count = 0
  while true do
    local byte = byte_at(message, position + count)
    if not byte then fail("Malformed MIDI meta-event length.") end
    value = value * 128 + (byte % 128)
    count = count + 1
    if value > MAX_VLQ then fail("MIDI meta-event length exceeds the VLQ range.") end
    if byte < 0x80 then return value, count end
    if count == 4 then fail("MIDI variable-length quantity is too long.") end
  end
end

-- REAPER exposes legacy project-name bytes in the UTF-8 form of their
-- codepoints on some platforms (for example raw 0x82 becomes C2 82).  Native
-- MIDI export preserves the project bytes, so recover that form only when a
-- C1 control-range expansion proves this is such a name.  Ordinary UTF-8
-- names do not contain those expansions and pass through unchanged.
local function restore_legacy_name_bytes(name)
  local expanded = false
  local position = 1
  while position < #name do
    if name:byte(position) == 0xC2 then
      local next_byte = name:byte(position + 1)
      if next_byte and next_byte >= 0x80 and next_byte <= 0x9F then
        expanded = true
        break
      end
    end
    position = position + 1
  end
  if not expanded then return name end

  local bytes = {}
  position = 1
  while position <= #name do
    local first = name:byte(position)
    local second = name:byte(position + 1)
    if first == 0xC2 and second and second >= 0x80 and second <= 0xBF then
      table.insert(bytes, string.char(second))
      position = position + 2
    elseif first == 0xC3 and second and second >= 0x80 and second <= 0xBF then
      table.insert(bytes, string.char(second + 0x40))
      position = position + 2
    else
      table.insert(bytes, string.char(first))
      position = position + 1
    end
  end
  return table.concat(bytes)
end

local function meta_event(message)
  if #message < 2 or byte_at(message, 1) ~= 0xFF then
    fail("Malformed MIDI meta-event.")
  end
  if byte_at(message, 2) == 0x2F then return nil end
  local payload = message:sub(3)
  if byte_at(message, 2) == 0x03 then
    payload = restore_legacy_name_bytes(payload)
  end
  return string.char(0xFF, byte_at(message, 2)) .. vlq(#payload) .. payload
end

local function sysex_event(message)
  local status = byte_at(message, 1)
  if #message < 1 or (status ~= 0xF0 and status ~= 0xF7) then
    fail("Malformed system-exclusive event.")
  end
  return string.char(status) .. vlq(#message - 1) .. message:sub(2)
end

local function system_escape(message)
  return string.char(0xF7) .. vlq(#message) .. message
end

local function to_smf_event(message)
  local status = byte_at(message, 1)
  if not status then fail("Empty MIDI event.") end

  -- REAPER-only CC shape metadata is not an SMF event.
  if is_ccbz(message) then return nil end
  if status >= 0x80 and status <= 0xEF then
    return validate_channel_message(message)
  end
  if status == 0xF0 or status == 0xF7 then
    return sysex_event(message)
  end
  if status == 0xFF then
    return meta_event(message)
  end

  -- SMF has no ordinary event form for system common/realtime messages.
  -- Its F7 escape form is the lossless representation for arbitrary bytes.
  if status == 0xF1 or status == 0xF3 then
    if #message ~= 2 then fail("Malformed one-data-byte system message.") end
  elseif status == 0xF2 then
    if #message ~= 3 then fail("Malformed song-position system message.") end
  elseif status == 0xF6 or status >= 0xF8 then
    if #message ~= 1 then fail("Malformed system realtime message.") end
  else
    fail(string.format("Unsupported MIDI status 0x%02X.", status))
  end
  return system_escape(message)
end

local MIDI_SCOPES = { [0] = "all", [1] = "selected_tracks", [2] = "selected_items" }

local function choose_output_file(initial_path)
  ---@type fun(mode: integer, caption: string, initial_file_or_path: string, extension_list: string): boolean, string
  local get_user_file_name = rawget(reaper, "GetUserFileName")
  if not get_user_file_name then
    fail("This exporter requires a REAPER version with GetUserFileName support.")
  end
  return get_user_file_name(
    0,
    "PAGER - MIDI Export",
    initial_path,
    "MIDI files|*.mid|All files|*.*"
  )
end

-- Source selection ----------------------------------------------------------
-- Collects the MIDI takes the settings ask for, in project track order then
-- item order, so Format 1 track order is deterministic.

local function item_bounds_qn(item)
  local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return reaper.TimeMap2_timeToQN(0, position),
    reaper.TimeMap2_timeToQN(0, position + length)
end

local function time_selection_qn()
  local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if not start_time or not end_time or end_time <= start_time then
    fail("Set a time selection before exporting with time-selection consolidation.")
  end
  return reaper.TimeMap2_timeToQN(0, start_time),
    reaper.TimeMap2_timeToQN(0, end_time)
end

local function start_time_of(item)
  return reaper.GetMediaItemInfo_Value(item, "D_POSITION")
end

local function item_track(item)
  if reaper.GetMediaItemTrack then return reaper.GetMediaItemTrack(item) end
  return nil
end

-- A track's I_MIDIHWOUT packs the hardware output device and a forced channel
-- into one integer: device = floor(value / 32), channel = value & 0x1F (0 for
-- "use the authored channel").  Per the REAPER state-chunk definition of
-- MIDIOUT, a track with no hardware output reports a negative value.
--
-- The device index is what separates one port from the next, so it is the port
-- number written to the file.  The forced channel is deliberately ignored:
-- this exporter writes the take's authored channels unchanged.
-- A track inside a folder usually carries no output of its own: the routing is
-- set once on the folder parent and every child plays through it.  Those
-- children report -1, so reading only the track's own value puts a whole
-- folder on port 0.  Walk up until a track names a device, which is the track
-- that actually reaches the hardware.
local function track_port(track)
  if not track or not reaper.GetMediaTrackInfo_Value then return 0 end

  local current = track
  -- A malformed parent chain would otherwise spin here; no real project nests
  -- anywhere near this deep.
  for _ = 1, 64 do
    local hwout = reaper.GetMediaTrackInfo_Value(current, "I_MIDIHWOUT")
    if hwout and hwout >= 0 then return math.floor(hwout / 32) end
    if not reaper.GetParentTrack then return 0 end
    current = reaper.GetParentTrack(current)
    if not current then return 0 end
  end
  return 0
end

local function track_name(track)
  if not track or not reaper.GetSetMediaTrackInfo_String then return nil end
  local ok, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if ok and name and name ~= "" then return restore_legacy_name_bytes(name) end
  return nil
end

local function midi_source(item)
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then return nil end
  local start_qn, end_qn = item_bounds_qn(item)
  local track = item_track(item)
  local looped = false
  if reaper.GetMediaItemInfo_Value then
    looped = reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") == 1
  end

  -- The loop period is the take's source length.  REAPER reports it in
  -- quarter notes for QN-based MIDI sources, which is the unit used here.
  local source_length_qn = nil
  if looped and reaper.GetMediaItemTakeInfo_Value and reaper.GetMediaItemTake_Source then
    local pcm_source = reaper.GetMediaItemTake_Source(take)
    if pcm_source and reaper.GetMediaSourceLength then
      local length, is_qn = reaper.GetMediaSourceLength(pcm_source)
      if length and length > 0 then
        if is_qn then
          source_length_qn = length
        else
          -- A time-based length still has to be expressed in QN to line up
          -- with event positions.
          source_length_qn = reaper.TimeMap2_timeToQN(0, start_time_of(item) + length)
            - reaper.TimeMap2_timeToQN(0, start_time_of(item))
        end
      end
    end
    local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    if source_length_qn and rate and rate > 0 then
      source_length_qn = source_length_qn / rate
    end
  end
  return {
    item = item,
    take = take,
    track = track,
    track_name = track_name(track),
    port = track_port(track),
    start_qn = start_qn,
    end_qn = end_qn,
    looped = looped,
    source_length_qn = source_length_qn,
  }
end

local function scoped_items(midi_scope)
  local items = {}
  if midi_scope == "selected_items" then
    for index = 0, reaper.CountSelectedMediaItems(0) - 1 do
      table.insert(items, reaper.GetSelectedMediaItem(0, index))
    end
    return items
  end

  local tracks = {}
  if midi_scope == "selected_tracks" then
    for index = 0, reaper.CountSelectedTracks(0) - 1 do
      table.insert(tracks, reaper.GetSelectedTrack(0, index))
    end
  else
    for index = 0, reaper.CountTracks(0) - 1 do
      table.insert(tracks, reaper.GetTrack(0, index))
    end
  end

  for _, track in ipairs(tracks) do
    for index = 0, reaper.CountTrackMediaItems(track) - 1 do
      table.insert(items, reaper.GetTrackMediaItem(track, index))
    end
  end
  return items
end

local function selected_midi_sources(settings)
  local sources = {}
  local range_start, range_end
  if settings.consolidate_mode == "time_selection" then
    range_start, range_end = time_selection_qn()
  end

  for _, item in ipairs(scoped_items(settings.midi_scope)) do
    local source = midi_source(item)
    -- An item contributes when it overlaps the range at all; its events are
    -- clipped to the range later, during rebasing.
    if source and (not range_start
      or (source.start_qn < range_end and source.end_qn > range_start)) then
      table.insert(sources, source)
    end
  end

  if #sources == 0 then
    fail("The current selection contains no MIDI takes to export.")
  end
  return sources
end

local function consolidation_bounds(settings, sources)
  if settings.consolidate_mode == "time_selection" then
    local start_qn, end_qn = time_selection_qn()
    return { start_qn = start_qn, end_qn = end_qn }
  end

  local start_qn = math.huge
  local end_qn = -math.huge
  for _, source in ipairs(sources) do
    start_qn = math.min(start_qn, source.start_qn)
    end_qn = math.max(end_qn, source.end_qn)
  end
  return { start_qn = start_qn, end_qn = end_qn }
end

-- Drops events outside the consolidation range and rezeroes the survivors so
-- output ticks always start at zero.  Both bounds are inclusive: an event
-- exactly on the range end is part of the selection.
local function rebase_events(events, bounds)
  local kept = {}
  local epsilon = 1e-9
  for _, event in ipairs(events) do
    if event.qn >= bounds.start_qn - epsilon
      and event.qn <= bounds.end_qn + epsilon then
      event.qn = event.qn - bounds.start_qn
      table.insert(kept, event)
    end
  end
  return kept
end

local function take_events(take)
  MIDIUtils.MIDI_InitializeTake(take)

  local events = {}
  local sequence = 0

  -- MIDI_GetEvt hands back every event of the take in order, already unpacked
  -- into its own bytes, so there is no packed buffer to walk and no truncated
  -- record to guard against.  Ticks are absolute, not deltas.
  local total = MIDIUtils.MIDI_CountAllEvts(take)
  for index = 0, (total or 0) - 1 do
    local ok, _, _, ppq, message = MIDIUtils.MIDI_GetEvt(take, index)
    if ok and message then
      local absolute_ppq = math.floor((ppq or 0) + 0.5)

      -- Native REAPER MIDI export writes muted item events too. SMF has no
      -- mute flag, so the mute state is intentionally not serialized.
      if #message > 0 then
        local smf_message = to_smf_event(message)
        if smf_message then
          sequence = sequence + 1
          local event = {
            ppq = absolute_ppq,
            message = smf_message,
            sequence = sequence,
          }
          table.insert(events, event)
        end
      end
    end
  end

  if #events == 0 then fail("The selected take contains no exportable MIDI events.") end
  return events
end

local function project_qn(take, ppq)
  return reaper.MIDI_GetProjQNFromPPQPos(take, ppq)
end

-- Optional metadata ---------------------------------------------------------
-- Each class is written only when its dialog toggle is on, and never alters
-- the ordinary MIDI events around it.

local function meta_message(kind, payload)
  return string.char(0xFF, kind) .. vlq(#payload) .. payload
end

-- Project markers become SMF marker meta events (0xFF 0x06).  Regions are
-- skipped: SMF has no region form, and native export writes markers only.
local function marker_events(settings, bounds)
  local events = {}
  if not settings.embed_markers then return events end

  local total = reaper.CountProjectMarkers(0)
  for index = 0, total - 1 do
    local ok, is_region, position, _, name = reaper.EnumProjectMarkers(index)
    if ok and ok ~= 0 and not is_region then
      local label = name or ""
      local is_hash = label:sub(1, 1) == "#"
      -- The "only # markers" option keeps the hash-prefixed markers and drops
      -- the rest; the marker name itself is written unchanged.
      if not settings.markers_hash_only or is_hash then
        local qn = reaper.TimeMap2_timeToQN(0, position)
        if qn >= bounds.start_qn and qn <= bounds.end_qn then
          table.insert(events, {
            qn = qn - bounds.start_qn,
            message = meta_message(0x06, label),
            priority = -3,
            sequence = index,
          })
        end
      end
    end
  end
  return events
end

-- SMPTE offset (0xFF 0x54) describes the file's start time.  The prototype
-- writes a zero offset at the project frame rate, which is what native export
-- produces for a project starting at 00:00:00:00.
local function smpte_offset_event(settings)
  if not settings.embed_smpte then return nil end

  local frame_rate = 30
  if reaper.GetSetProjectInfo then
    local value = reaper.GetSetProjectInfo(0, "PROJECT_FRAMERATE", 0, false)
    if value and value > 0 then frame_rate = math.floor(value + 0.5) end
  end

  -- SMF encodes the frame rate in the top two bits of the hour byte.
  local rate_bits = 0
  if frame_rate == 25 then rate_bits = 0x20
  elseif frame_rate == 29 then rate_bits = 0x40
  elseif frame_rate == 30 then rate_bits = 0x60 end

  return {
    qn = 0,
    message = meta_message(0x54, string.char(rate_bits, 0, 0, 0, 0)),
    priority = -4,
    sequence = -4,
  }
end


local function add_tempo_and_time_signatures(events, take, origin_qn, last_qn)
  local marker_count = reaper.CountTempoTimeSigMarkers(0)
  local previous_bpm = 120
  local initial_num = 4
  local initial_denom = 4
  local current_num = 4
  local current_denom = 4
  local markers = {}

  for index = 0, marker_count - 1 do
    local ok, time_position, _, _, bpm, numerator, denominator =
      reaper.GetTempoTimeSigMarker(0, index)
    if ok and bpm and bpm > 0 then
      local marker_num = numerator and numerator > 0 and numerator or current_num
      local marker_denom = denominator and denominator > 0 and denominator or current_denom
      local qn = project_qn(take, reaper.MIDI_GetPPQPosFromProjTime(take, time_position))
      if qn <= origin_qn then
        previous_bpm = bpm
        initial_num = marker_num
        initial_denom = marker_denom
      elseif qn <= last_qn then
        table.insert(markers, {
          qn = qn,
          bpm = bpm,
          numerator = marker_num,
          denominator = marker_denom,
          sequence = index,
        })
      end
      current_num = marker_num
      current_denom = marker_denom
    end
  end

  local function tempo_message(bpm)
    return string.char(0xFF, 0x51, 0x03) .. u24(math.floor(60000000 / bpm + 0.5))
  end

  local function time_signature_message(numerator, denominator)
    local power = 0
    local value = denominator
    while value > 1 and value % 2 == 0 do
      power = power + 1
      value = value / 2
    end
    if value ~= 1 or power > 255 then return nil end
    return string.char(0xFF, 0x58, 0x04, numerator % 256, power, 24, 8)
  end

  table.insert(events, {
    qn = origin_qn,
    message = tempo_message(previous_bpm),
    priority = -1,
    sequence = -1,
  })
  local initial_time_signature = time_signature_message(initial_num, initial_denom)
  local last_signature_num = initial_num
  local last_signature_denom = initial_denom
  if initial_time_signature then
    table.insert(events, {
      qn = origin_qn,
      message = initial_time_signature,
      priority = -2,
      sequence = -2,
    })
  end

  for _, marker in ipairs(markers) do
    table.insert(events, {
      qn = marker.qn,
      message = tempo_message(marker.bpm),
      priority = -1,
      sequence = marker.sequence,
    })
    local signature = time_signature_message(marker.numerator, marker.denominator)
    if signature and (marker.numerator ~= last_signature_num
      or marker.denominator ~= last_signature_denom) then
      table.insert(events, {
        qn = marker.qn,
        message = signature,
        priority = -2,
        sequence = marker.sequence,
      })
      last_signature_num = marker.numerator
      last_signature_denom = marker.denominator
    end
  end
end

-- Gated wrapper around the verified tempo/time-signature builder.  When the
-- toggle is off the file carries no tempo map, and no other event class is
-- affected.
local function tempo_events(settings, take, bounds)
  local events = {}
  if not settings.embed_tempo then return events end
  add_tempo_and_time_signatures(events, take, bounds.start_qn, bounds.end_qn)
  for _, event in ipairs(events) do
    event.qn = event.qn - bounds.start_qn
  end
  return events
end

-- Shared MTrk encoding.  Events carry absolute QN; ticks are derived here so
-- Format 0 and Format 1 share one ordering and delta-time implementation.
-- Equal ticks order by priority then sequence, which keeps metadata ahead of
-- the channel events recorded at the same instant.
local function encode_track(events, output_ppq)
  for _, event in ipairs(events) do
    event.tick = math.floor(event.qn * output_ppq + 0.5)
  end

  local loop_open_ticks = {}
  for _, event in ipairs(events) do
    local status = event.message:byte(1) or 0
    local kind = status - (status % 16)
    if kind == 0x90 and (event.message:byte(3) or 0) > 0 then
      loop_open_ticks[event.tick] = true
    end
  end

  table.sort(events, function(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    -- Bank select and program change lead the tick, across every track:
    -- native emits each track's patch setup before any track's performance
    -- events, so a program change always reaches the device before the notes
    -- it applies to.
    if (a.setup_rank or 0) ~= (b.setup_rank or 0) then
      return (a.setup_rank or 0) < (b.setup_rank or 0)
    end
    local a_boundary = a.item_boundary_note_off
      or (a.loop_boundary_note_off and loop_open_ticks[a.tick])
    local b_boundary = b.item_boundary_note_off
      or (b.loop_boundary_note_off and loop_open_ticks[b.tick])
    if (a_boundary and 1 or 0) ~= (b_boundary and 1 or 0) then
      return a_boundary == true
    end
    -- Source track ranks above the take-local keys: native groups a tick's
    -- events by track.  Metadata carries no track index and so stays ahead of
    -- every track's events.
    if (a.track_index or 0) ~= (b.track_index or 0) then
      return (a.track_index or 0) < (b.track_index or 0)
    end
    if (a.priority or 0) ~= (b.priority or 0) then
      return (a.priority or 0) < (b.priority or 0)
    end
    return a.sequence < b.sequence
  end)

  local track = {}
  local last_tick = 0
  for _, event in ipairs(events) do
    local delta = event.tick - last_tick
    if delta < 0 then fail("MIDI event ordering produced a negative delta-time.") end
    table.insert(track, vlq(delta) .. event.message)
    last_tick = event.tick
  end
  table.insert(track, "\0\255\47\0")
  return table.concat(track)
end

local function smf_header(format, track_count, output_ppq)
  return "MThd" .. u32(6) .. u16(format) .. u16(track_count) .. u16(output_ppq)
end

local function chunk(track)
  return "MTrk" .. u32(#track) .. track
end

local function require_tracks(tracks)
  if not tracks or #tracks == 0 then
    fail("The current selection contains no MIDI events to export.")
  end
end

-- Format 0 merges every selected track into a single MTrk.
local function assemble_format_zero(tracks, settings, metadata)
  require_tracks(tracks)
  local merged = {}
  for _, event in ipairs(metadata or {}) do table.insert(merged, event) end
  -- Within a tick, native orders every event by its source track: a track's
  -- events at that tick are written together, tracks in project order.  The
  -- events themselves still interleave across ticks.  Priority and sequence
  -- are take-local, so they cannot express this on their own.
  -- Bank select (CC0/CC32) and program change are a patch-setup class that
  -- native collects across tracks at a tick: every bank, then every program
  -- change, then the performance events.  The exception is the tick where a
  -- track's events begin: there its setup belongs to that track's own opening
  -- block, so the per-track grouping applies instead.
  local function setup_rank(message)
    local status = message:byte(1) or 0
    local kind = status - (status % 16)
    if kind == 0xC0 then return -1 end
    if kind == 0xB0 then
      local controller = message:byte(2)
      if controller == 0 or controller == 32 then return -2 end
    end
    return 0
  end

  -- A tick where any track's events begin keeps every track's setup inside
  -- its own block; only later ticks collect the setup across tracks.
  local opening_qn = {}
  for _, events in ipairs(tracks) do
    local start_qn = math.huge
    for _, event in ipairs(events) do
      start_qn = math.min(start_qn, event.qn)
    end
    opening_qn[start_qn] = true
  end

  for index, events in ipairs(tracks) do
    for _, event in ipairs(events) do
      event.track_index = index
      if opening_qn[event.qn] then
        event.setup_rank = 0
      else
        event.setup_rank = setup_rank(event.message)
      end
      table.insert(merged, event)
    end
  end
  local track = encode_track(merged, settings.output_ppq)
  return smf_header(0, 1, settings.output_ppq) .. chunk(track)
end

-- Format 1 writes a dedicated metadata track first, then one MTrk per
-- selected source track in source order.  Native REAPER export puts the
-- track name, SMPTE offset, time signatures and tempo map on track 0 and
-- keeps channel events off it entirely.
local function assemble_format_one(tracks, settings, metadata)
  require_tracks(tracks)
  local chunks = {}
  if metadata then
    table.insert(chunks, chunk(encode_track(metadata, settings.output_ppq)))
  end
  for _, events in ipairs(tracks) do
    -- FF 21 is the de-facto MIDI port meta: one byte naming the port this
    -- track plays on, which is how a file addresses more than 16 channels.
    -- It is not in RP-001 or RP-019, but it is what players actually read to
    -- keep two tracks on the same channel apart.  Written at tick 0 ahead of
    -- everything sendable, and only when the export is multi-port, so an
    -- ordinary single-port file is unchanged.
    if settings.multi_port and events.port then
      table.insert(events, {
        qn = 0,
        message = meta_message(0x21, string.char(events.port % 256)),
        priority = -6,
        sequence = -6,
      })
    end
    table.insert(chunks, chunk(encode_track(events, settings.output_ppq)))
  end
  return smf_header(1, #chunks, settings.output_ppq) .. table.concat(chunks)
end

-- Builds one event list per selected source, already rebased to the
-- consolidation start, so the format layer only has to encode them.
-- Native Format 1 export writes one MTrk per REAPER track, not per take, so
-- a track holding several MIDI items contributes one merged track.  Takes are
-- grouped by their parent track, preserving first-appearance order.
-- A looped MIDI item plays its source repeatedly until the item ends.
-- A take holds a single pass, so the remaining repetitions are materialized
-- here and clipped to the item's end.
local function expand_loop(events, source)
  if not source.looped or #events == 0 then return events end

  -- The source period is the take's own length, which is where REAPER wraps.
  local period = source.source_length_qn
  if not period or period <= 0 then return events end

  local span = source.end_qn - source.start_qn
  if span <= period then return events end

  local expanded = {}
  for _, event in ipairs(events) do table.insert(expanded, event) end

  -- Each repetition sorts entirely after the previous one, so a note-off
  -- ending one pass precedes the note-on starting the next at a shared tick.
  -- A per-event fraction is not enough: the next pass's early events would
  -- still outrank this pass's late ones.
  local highest = 0
  for _, event in ipairs(events) do
    if (event.sequence or 0) > highest then highest = event.sequence or 0 end
  end
  local stride = highest + 1

  local repeats = math.ceil(span / period) - 1
  for index = 1, repeats do
    local shift = period * index
    for _, event in ipairs(events) do
      local qn = event.qn + shift
      -- The item end is exclusive for events that start sound and inclusive
      -- for the note-offs that close it, so a note ending exactly on the
      -- item edge is not left hanging.
      local status = event.message:byte(1) or 0
      local kind = status - (status % 16)
      local is_note_off = kind == 0x80
        or (kind == 0x90 and (event.message:byte(3) or 0) == 0)
      local within = is_note_off and qn <= source.end_qn or qn < source.end_qn
      if within then
        local copy = {}
        for k, v in pairs(event) do copy[k] = v end
        copy.qn = qn
        -- Keep repeats after the originals at equal ticks.
        copy.sequence = (event.sequence or 0) + stride * index
        table.insert(expanded, copy)
      end
    end
  end
  return expanded
end

local function source_tracks(settings, sources, bounds)
  local groups = {}
  local order = {}
  local next_item_starts = {}

  for _, source in ipairs(sources) do
    local key = source.track or source
    next_item_starts[key] = next_item_starts[key] or {}
    table.insert(next_item_starts[key], source.start_qn)
  end

  local function same_qn(a, b)
    return math.abs(a - b) < 1e-9
  end

  local function track_has_item_start(track, qn, excluded)
    if not track or not reaper.CountTrackMediaItems
      or not reaper.GetTrackMediaItem then
      return false
    end
    for index = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, index)
      if item ~= excluded then
        local start_qn = item_bounds_qn(item)
        if same_qn(start_qn, qn) then return true end
      end
    end
    return false
  end

  for _, source in ipairs(sources) do
    local events = take_events(source.take)
    local key = source.track or source
    local has_next_item_at_end = track_has_item_start(
      source.track, source.end_qn, source.item
    )
    for _, start_qn in ipairs(next_item_starts[key] or {}) do
      if same_qn(start_qn, source.end_qn)
        then has_next_item_at_end = true; break end
    end
    local has_source_track_name_at_start = false
    for _, event in ipairs(events) do
      if event.qn == nil then
        event.qn = project_qn(source.take, event.ppq)
      end
      if event.message:byte(1) == 0xFF and event.message:byte(2) == 0x03
        and same_qn(event.qn, bounds.start_qn) then
        has_source_track_name_at_start = true
      end
      local status = event.message:byte(1) or 0
      local kind = status - (status % 16)
      if has_next_item_at_end and same_qn(event.qn, source.end_qn)
        and (kind == 0x80
          or (kind == 0x90 and (event.message:byte(3) or 0) == 0)) then
        event.item_boundary_note_off = true
      end
    end
    events = expand_loop(events, source)
    if source.looped and source.source_length_qn
      and source.source_length_qn > 0 then
      for _, event in ipairs(events) do
        local offset = event.qn - source.start_qn
        local cycle = math.floor(offset / source.source_length_qn + 0.5)
        local status = event.message:byte(1) or 0
        local kind = status - (status % 16)
        local note_off = kind == 0x80
          or (kind == 0x90 and (event.message:byte(3) or 0) == 0)
        if cycle >= 1 and note_off
          and math.abs(offset - cycle * source.source_length_qn) < 1e-9 then
          event.loop_boundary_note_off = true
        end
      end
    end
    local kept = rebase_events(events, bounds)
    if #kept > 0 then
      -- Takes with no resolvable parent track stay separate rather than
      -- being merged together by a shared nil key.
      local group = groups[key]
      if not group then
        group = {
          events = {},
          name = source.track_name,
          port = source.port or 0,
          has_source_track_name_at_start = has_source_track_name_at_start,
          sequence_base = 0,
        }
        groups[key] = group
        table.insert(order, key)
      elseif has_source_track_name_at_start then
        group.has_source_track_name_at_start = true
      end
      -- Each take numbers its events from zero, so a later item on the same
      -- track is shifted past the previous one.  Without this, events from
      -- two items sharing a tick interleave by take-local order and a note
      -- from the new item can precede the previous item's note-off.
      local highest = 0
      for _, event in ipairs(kept) do
        event.sequence = (event.sequence or 0) + group.sequence_base
        if event.sequence > highest then highest = event.sequence end
        table.insert(group.events, event)
      end
      group.sequence_base = highest + 1
    end
  end

  local tracks = {}
  for _, key in ipairs(order) do
    local group = groups[key]
    -- A source take's own track-name meta-event is authoritative.  Native
    -- only falls back to the REAPER track name when the take has no embedded
    -- name.  Format 0 merges every source into one track, so native writes no
    -- per-track fallback name there.
    if group.name and not group.has_source_track_name_at_start and settings.format == 1 then
      table.insert(group.events, {
        qn = 0,
        message = meta_message(0x03, group.name),
        priority = -5,
        sequence = -5,
      })
    end
    -- The port rides on the event list as a field rather than wrapping it, so
    -- the list stays an ordinary array of events for every other consumer.
    group.events.port = group.port or 0
    table.insert(tracks, group.events)
  end
  return tracks
end

local function export_with_settings(settings)
  local sources = selected_midi_sources(settings)
  local bounds = consolidation_bounds(settings, sources)
  local tracks = source_tracks(settings, sources, bounds)
  if #tracks == 0 then
    fail("The current selection contains no MIDI events in the export range.")
  end

  -- Native stops the embedded tempo map at the final exported MIDI event,
  -- rather than carrying project tempo markers through the item's full span.
  -- Track events are already rebased to the consolidation start here.
  local latest_event_qn = 0
  for _, track_events in ipairs(tracks) do
    for _, event in ipairs(track_events) do
      if event.qn > latest_event_qn then latest_event_qn = event.qn end
    end
  end
  local tempo_bounds = {
    start_qn = bounds.start_qn,
    end_qn = bounds.start_qn + latest_event_qn,
  }

  -- Format 0 merges metadata into its single track; Format 1 gets it as a
  -- dedicated leading track, which is what native export writes.
  local metadata = tempo_events(settings, sources[1].take, tempo_bounds)
  local smpte = smpte_offset_event(settings)
  if smpte then table.insert(metadata, smpte) end
  for _, event in ipairs(marker_events(settings, bounds)) do
    table.insert(metadata, event)
  end

  -- Which ports the selected tracks actually resolve to.  A file whose tracks
  -- all share one port needs no port metas at all, so they are written only
  -- when the export really spans more than one.
  --
  -- The device index counts every output device REAPER knows about, including
  -- disabled ones, so two adjacent hardware outputs can be devices 2 and 3.
  -- A player maps the port number straight onto its own outputs -- on an
  -- SC-8850, port 2 is PART-C -- so the devices are renumbered densely from
  -- zero, in device order.  What the file has to preserve is which tracks
  -- share a port, not REAPER's numbering of them.
  local device_order = {}
  for _, track_events in ipairs(tracks) do
    local device = track_events.port or 0
    if not device_order[device] then device_order[device] = true end
  end

  local devices = {}
  for device in pairs(device_order) do table.insert(devices, device) end
  table.sort(devices)

  local port_of_device = {}
  for index, device in ipairs(devices) do
    port_of_device[device] = index - 1
  end
  for _, track_events in ipairs(tracks) do
    track_events.port = port_of_device[track_events.port or 0]
  end

  local port_count = #devices
  settings.multi_port = port_count > 1

  local midi
  if settings.format == 1 then
    -- Native names track 0 after the exported file.
    local name = settings.output_path:match("([^/\\]+)%.[Mm][Ii][Dd]$")
    if name then
      table.insert(metadata, {
        qn = 0,
        message = meta_message(0x03, name),
        priority = -5,
        sequence = -5,
      })
    end
    midi = assemble_format_one(tracks, settings, metadata)
  else
    midi = assemble_format_zero(tracks, settings, metadata)
  end

  local file, error_message = io.open(settings.output_path, "wb")
  if not file then
    fail("Could not write file:\n" .. tostring(error_message))
    return
  end
  file:write(midi)
  file:close()

  -- Format 0 has a single track, so it can carry only one port meta and every
  -- track's channels collapse back into one 16-channel stream.  Say so rather
  -- than writing a file that quietly loses the port separation.
  local port_note = ""
  if port_count > 1 then
    if settings.format == 1 then
      port_note = "\nPorts: " .. port_count ..
        " (FF 21 port meta written per track)"
    else
      port_note = "\nPorts: " .. port_count ..
        " found, but format 0 has a single track, so port separation was" ..
        "\ndropped. Export as format 1 for more than 16 channels."
    end
  else
    -- Every track resolving to one port means the file is a plain 16-channel
    -- file, however many tracks it has.  That is easy to mistake for a
    -- multi-port export, so it is stated rather than left to the player to
    -- reveal.
    port_note = "\nPorts: 1 (16 channels). Set a MIDI hardware output on the" ..
      "\ntracks, or on their folder parent, to export more."
  end

  -- A successful export closes the window and returns to PAGER, so its
  -- confirmation cannot be a modal -- there would be nothing behind it to
  -- dismiss back to.  The summary is returned instead: the launcher shows the
  -- filename, and the detail is available to whoever asks for it.
  return {
    path = settings.output_path,
    name = settings.output_path:match("[^/\\]+$") or settings.output_path,
    summary = "Wrote all exportable MIDI events to:\n" .. settings.output_path ..
      "\n\nOutput PPQ: " .. settings.output_ppq ..
      "\nFormat: " .. settings.format ..
      "\nSources: " .. #sources .. ", tracks written: " ..
      (settings.format == 1 and #tracks or 1) ..
      port_note,
  }
end

-- ReaImGui front end --------------------------------------------------------
-- Draws the controls REAPER's own "Export project MIDI" dialog uses. Options
-- this exporter does not
-- implement are simply absent rather than shown disabled: cue-point markers
-- (only FF 06 is written) and port metas.
-- The window title, and the name this tool reports itself under.  One
-- constant so the title bar, the error boxes and the session-state key cannot
-- drift apart.
local TOOL_TITLE = "PAGER - MIDI Export"
local SESSION_TOOL = "midi_export"

-- Per-visit state: every field the dialog exposes, restored on the next visit
-- so a second export does not start from defaults.  Built fresh each start()
-- because the default path depends on the project, which can change.
local function default_cfg()
  return {
    path = reaper.GetProjectPath() .. "/prototype-midi-export.mid",
    time_selection = false,
    items = 0, -- 0 all, 1 selected tracks, 2 selected items
    -- Type 1 by default: it keeps one MTrk per source track, which is what
    -- multi-port output needs and what preserves track names.
    format = 1,
    output_ppq = DEFAULT_OUTPUT_PPQ,
    embed_tempo = true,
    embed_smpte = false,
    embed_markers = false,
    markers_hash_only = false,
  }
end

-- Only plain scalars cross the session boundary, and every one of them is
-- checked against the default's type on the way back in: the record can only
-- have been written by this same process, but it is decoded JSON either way,
-- and a string where a number belongs would reach the encoder as a malformed
-- PPQ rather than as a visible error.
local function restore_cfg(cfg, saved)
  if type(saved) ~= "table" then return false end
  for key, default in pairs(cfg) do
    local v = saved[key]
    if type(v) == type(default) then cfg[key] = v end
  end
  -- The path is the one field a user can make nonsense of, and an empty one
  -- would write to the project root; fall back rather than accept it.
  if type(cfg.path) ~= "string" or cfg.path == "" then
    cfg.path = default_cfg().path
  end
  return true
end

local function run_imgui(ImGui, Theme, on_close, session)
  local ctx = ImGui.CreateContext(TOOL_TITLE)
  ImGui.SetConfigVar(ctx, ImGui.ConfigVar_ViewportsNoDecoration, 0)

  local cfg = default_cfg()

  -- The project this window is bound to.  A change means the user switched
  -- REAPER project tabs, which saves the old settings and loads that tab's.
  local bound_project = session:project_key()
  if restore_cfg(cfg, session:load(SESSION_TOOL)) then
    -- nothing to announce: unlike the Effects Editor these values reach no
    -- hardware, so there is nothing for the user to be warned about.
  end

  local status, status_time = "", 0
  local STATUS_SECS = 4
  local want_close = false
  -- The export result handed back to PAGER, or nil when the window is closed
  -- without a successful export.
  local result
  local function set_status(message)
    status, status_time = message, reaper.time_precise()
  end

  -- The single exit.  Guarded: the Cancel button and the window close button
  -- can both fire, and PAGER must be reopened exactly once either way.
  local closed = false
  local function finish()
    if closed then return end
    closed = true
    session:save(SESSION_TOOL, cfg)
    -- Releasing the context is dropping the reference: ReaImGui has no
    -- DestroyContext, and collects unattached objects that are left unused.
    -- ctx is a local to this run_imgui call, so it goes when the closure does.
    ctx = nil
    if on_close then on_close(result) end
  end

  -- Settings follow the active project tab, exactly as the Effects Editor's
  -- values do, so an export started from one tab cannot be configured against
  -- another's paths.
  local function check_project()
    local now = session:project_key()
    if now == bound_project then return end

    -- Each call names its project: REAPER reports `now` already, while these
    -- settings still belong to `bound_project`.  Letting the module resolve it
    -- would write the old tab's settings over the new tab's record.
    session:save(SESSION_TOOL, cfg, bound_project)
    local previous = session:load(SESSION_TOOL, now)
    bound_project = now
    cfg = default_cfg()
    restore_cfg(cfg, previous)
    set_status("Loaded this project's export settings.")
  end

  local function do_export()
    local ok, err = pcall(export_with_settings, {
      consolidate_mode = cfg.time_selection and "time_selection" or "project",
      midi_scope = MIDI_SCOPES[cfg.items],
      format = cfg.format,
      output_ppq = cfg.output_ppq,
      embed_tempo = cfg.embed_tempo,
      embed_smpte = cfg.embed_smpte,
      embed_markers = cfg.embed_markers,
      markers_hash_only = cfg.markers_hash_only,
      output_path = cfg.path,
    })
    -- Success closes the window and hands the filename to PAGER (the plan's
    -- non-modal confirmation).  Failure stays open with the reason on the
    -- status line, because the settings that caused it are still on screen
    -- and are what the user needs to change.
    if ok then
      result = err   -- pcall's second return is export_with_settings' value
      if type(result) ~= "table" then result = { name = cfg.path } end
      want_close = true
    else
      set_status("ERROR: " .. tostring(err))
    end
  end

  -- ImGui has no native group box, so it is a bordered child frame with a
  -- heading above it.  AutoResizeY lets the frame measure its own contents
  -- rather than guessing a height that clips at another font size or DPI.
  local function group(label, body)
    ImGui.Text(ctx, label)
    if ImGui.BeginChild(ctx, "##" .. label, 0, 0,
                        ImGui.ChildFlags_Borders | ImGui.ChildFlags_AutoResizeY) then
      ImGui.Dummy(ctx, 0, 2)
      body()
      ImGui.Dummy(ctx, 0, 2)
      ImGui.EndChild(ctx)
    end
  end

  local function frame()
    local _

    group("Input", function()
      -- GetContentRegionAvail returns x and y; only the width is wanted.
      local avail = ImGui.GetContentRegionAvail(ctx)
      local col = avail * 0.42

      -- Both columns are groups so they start on the same row.  SameLine after
      -- a bare run of widgets would attach the right column to the last row of
      -- the left one.
      ImGui.BeginGroup(ctx)
      ImGui.Text(ctx, "Consolidate time:")
      if ImGui.RadioButton(ctx, "Entire project", not cfg.time_selection) then
        cfg.time_selection = false
      end
      if ImGui.RadioButton(ctx, "Time selection only", cfg.time_selection) then
        cfg.time_selection = true
      end
      ImGui.EndGroup(ctx)

      ImGui.SameLine(ctx, col)
      ImGui.BeginGroup(ctx)
      ImGui.Text(ctx, "Consolidate MIDI items:")
      if ImGui.RadioButton(ctx, "All", cfg.items == 0) then cfg.items = 0 end
      if ImGui.RadioButton(ctx, "Selected tracks only", cfg.items == 1) then
        cfg.items = 1
      end
      if ImGui.RadioButton(ctx, "Selected items only", cfg.items == 2) then
        cfg.items = 2
      end
      ImGui.EndGroup(ctx)
    end)

    ImGui.Dummy(ctx, 0, 4)

    group("Output", function()
      ImGui.Text(ctx, "Export to MIDI file:")
      ImGui.SetNextItemWidth(ctx, -90)
      _, cfg.path = ImGui.InputText(ctx, "##path", cfg.path)
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Browse...") then
        local chosen, filename = choose_output_file(cfg.path)
        if chosen and filename and filename ~= "" then cfg.path = filename end
      end

      -- Both formats are implemented, so this is a real choice rather than the
      -- fixed type-1 statement the multi-port exporter shows.
      ImGui.Text(ctx, "MIDI file format:")
      ImGui.SameLine(ctx)
      if ImGui.RadioButton(ctx, "Type 0", cfg.format == 0) then
        cfg.format = 0
      end
      ImGui.SameLine(ctx)
      if ImGui.RadioButton(ctx, "Type 1", cfg.format == 1) then
        cfg.format = 1
      end

      ImGui.SetNextItemWidth(ctx, 90)
      _, cfg.output_ppq = ImGui.InputInt(ctx, "Output PPQ", cfg.output_ppq)
      -- The value goes in a u16, so keep it inside SMF's metrical range.
      if cfg.output_ppq < 1 then cfg.output_ppq = 1 end
      if cfg.output_ppq > 32767 then cfg.output_ppq = 32767 end

      _, cfg.embed_tempo =
        ImGui.Checkbox(ctx, "Embed project tempo/time signature changes",
                       cfg.embed_tempo)

      _, cfg.embed_smpte =
        ImGui.Checkbox(ctx, "Embed SMPTE offset", cfg.embed_smpte)

      _, cfg.embed_markers =
        ImGui.Checkbox(ctx, "Export project markers as MIDI", cfg.embed_markers)

      -- The marker filter means nothing with the box unticked, so it greys out
      -- with it rather than sitting there live and inert.
      if not cfg.embed_markers then ImGui.BeginDisabled(ctx) end
      ImGui.Indent(ctx, 20)
      _, cfg.markers_hash_only =
        ImGui.Checkbox(ctx, "Only export markers that begin with '#'",
                       cfg.markers_hash_only)
      ImGui.Unindent(ctx, 20)
      if not cfg.embed_markers then ImGui.EndDisabled(ctx) end
    end)

    ImGui.Dummy(ctx, 0, 4)

    if ImGui.Button(ctx, "OK", 90) then do_export() end
    ImGui.SameLine(ctx)
    -- Cancel is this tool's "Back to PAGER": same exit, no export.
    if ImGui.Button(ctx, "Cancel", 90) then want_close = true end

    if status ~= "" then
      if reaper.time_precise() - status_time > STATUS_SECS then
        status = ""
      else
        ImGui.SameLine(ctx)
        ImGui.Text(ctx, status)
      end
    end
  end

  local function loop()
    -- A frame can still be scheduled when the window has already gone: REAPER
    -- runs the deferred callback one more time after the one that closed.
    -- Drawing into a released context is a crash, not an error.
    if not ctx then return end

    -- A project-tab change is only observable by asking, so it is checked once
    -- per frame before anything is drawn from the values it may replace.
    check_project()

    Theme.begin_frame(ctx, ImGui)
    -- AlwaysAutoResize rather than a stored size: Cond_FirstUseEver is ignored
    -- once ImGui has a size for this window title in its .ini, so a measured
    -- number is right on a fresh install and stale everywhere else.  The width
    -- is set on Cond_Always because content cannot settle it -- the path field
    -- would otherwise stretch to whatever the current path happens to be.
    ImGui.SetNextWindowSize(ctx, 419, 0, ImGui.Cond_Always)
    local visible, open = ImGui.Begin(ctx, TOOL_TITLE, true,
                                      ImGui.WindowFlags_AlwaysAutoResize)
    if visible then
      -- End() must run even if frame() throws, or ImGui is left mid-window and
      -- reports "Missing End()" -- a second, louder error that buries the real
      -- one.  pcall keeps the two separate: the window closes properly and the
      -- actual message goes to the status line.
      local ok, err = pcall(frame)
      ImGui.End(ctx)
      if not ok then set_status("ERROR: " .. tostring(err)) end
    end
    Theme.end_frame(ctx, ImGui)
    if open and not want_close then
      reaper.defer(loop)
    else
      finish()
    end
  end

  reaper.defer(loop)
end

local function require_reaimgui()
  if not reaper.ImGui_GetBuiltinPath then
    fail(
      "ReaImGui 0.10 or newer is required.\n\n"
        .. "Install ReaImGui through ReaPack, then run this script again."
    )
  end

  package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
  local loaded, imgui_factory = pcall(require, "imgui")
  if not loaded or type(imgui_factory) ~= "function" then
    fail(
      "ReaImGui 0.10 or newer could not be loaded.\n\n"
        .. "Reinstall or update ReaImGui through ReaPack."
    )
  end
  return imgui_factory("0.10")
end

if rawget(_G, "MIDI_EXPORT_TEST") then
  return {
    selected_midi_sources = selected_midi_sources,
    consolidation_bounds = consolidation_bounds,
    rebase_events = rebase_events,
    encode_track = encode_track,
    assemble_format_zero = assemble_format_zero,
    assemble_format_one = assemble_format_one,
    marker_events = marker_events,
    smpte_offset_event = smpte_offset_event,
    tempo_events = tempo_events,
    source_tracks = source_tracks,
    require_reaimgui = require_reaimgui,
  }
end

-- Entry point.  PAGER calls this; on_close is invoked once, with the export
-- result when one succeeded and nil when the window was simply closed.
local function start(on_close)
  local script_dir = ({ reaper.get_action_context() })[2]
    :match("^(.*[/\\])") or ""
  package.path = script_dir .. "?.lua;" .. script_dir .. "../lib/?.lua;"
    .. package.path
  local ImGui = require_reaimgui()
  local Theme = require("theme")
  local SessionState = require("session_state")
  require_midiutils()
  run_imgui(ImGui, Theme, on_close, SessionState.new({ reaper = reaper }))
end

-- Required by PAGER, which calls start().  Run directly as an action it still
-- opens on its own, with no launcher to return to.
local M = { start = start }

if not rawget(_G, "PAGER_TOOL") then
  local ok, error_message = pcall(start, nil)
  if not ok then reaper.ShowConsoleMsg(tostring(error_message) .. "\n") end
end

return M
