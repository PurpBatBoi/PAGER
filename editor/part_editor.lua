-- PAGER - Part Editor
--
-- Edits one SC-8850 Part at a time. The port group comes from the hardware
-- output of the track being edited -- the take's track when a MIDI editor is
-- open, otherwise the selected track. Previewing needs only that route, so
-- the panel is live with nothing but a track selected; Insert is what needs a
-- take, and it alone is disabled without one. The Part follows the active MIDI editor's piano roll
-- until the user picks a channel from the header dropdown, after which the
-- pick wins for the rest of the visit -- REAPER offers no setter for
-- default_note_chan, so the dropdown cannot move the piano roll and must
-- simply outrank it. There is still no 16-column grid: one Part is edited at
-- a time.
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
local D = require 'drum_params'
local DM = require 'drum_messages'
local PartInsert = require 'part_insert'
local HardwareOutput = require 'hardware_output'
local SessionState = require 'session_state'
local Voices = require 'voices'

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
local WIN_W, WIN_H = 932, 650
local STATUS_SECS = 6

-- The gap between a row's label, its slider and its value, in pixels. One
-- constant so the three stay visually locked as a single row.
local LABEL_GAP = 8

-- The blank space between two clusters of rows on a page. XG separates its
-- groups this way instead of with a named header.
local CLUSTER_GAP = 10

local RESTORED_NOTICE = 'Restored values; not sent to hardware.'
-- What the header says about the current context, beside the channel picker.
--
-- Three states, and the middle one is the reason this tool no longer demands
-- a MIDI editor: with a track but no take the panel is fully live, every
-- control audible on the hardware, and NOTHING is being written to the
-- project. Saying so is the point -- a user who expects Insert to work needs
-- to know why it is greyed out, and a user who does not want events in their
-- item needs to know none are landing there.
local NO_TRACK_NOTICE = 'No track selected: select one with a MIDI hardware output.'
local PREVIEW_ONLY = 'Preview only: sending to hardware, not writing to the project.'
local EDITING = 'Previews to hardware; Insert writes at the edit cursor.'

-- per-channel state -----------------------------------------------------------

-- Sixteen independent channels, each holding its own control values and its
-- own Use SysEx? setting. Switching channel shows a different set; it sends
-- nothing and creates no pending edit.
--
-- `pending` is deliberately part of this table but NOT part of what is saved:
-- a pending snapshot is transient by design and must not survive closing the
-- tool or changing project tabs.
local channels = {}

local function blank_channel(part)
  local values = {}
  for _, p in ipairs(P.PARAMS) do values[p.id] = P.default_for(p, part) end

  -- Part 10 is the drum Part at power-on and every other Part is a normal
  -- one (manual p.238: MAP1 at x=0, OFF elsewhere). The row's own default
  -- cannot say this -- it is one value for all sixteen Parts -- so the one
  -- Part that differs is set here.
  if Voices.drum_at_power_on(part) then values.rhythm = 1 end
  -- The voice is an address into the tone map, not a parameter with a range,
  -- so it sits beside `values` rather than in it. `drum` decides which map
  -- the address is read against; Part 10 is the drum Part at power-on.
  return {
    values = values, use_sysex = false, pending = nil,
    voice = { msb = Voices.DEFAULT_MSB, lsb = Voices.DEFAULT_LSB,
              pc = Voices.DEFAULT_PC },
  }
end

local function reset_channels()
  channels = {}
  for i = 1, 16 do channels[i] = blank_channel(i) end
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

-- The track whose hardware output the previews go to.
--
-- A take's track when a MIDI editor is open, so an open editor keeps
-- addressing the part the user is looking at. Otherwise the first selected
-- track, which is the whole point: auditioning a Part needs a route, and a
-- route is a track property -- no MIDI item has to exist for one.
local function active_track(take)
  if take then return reaper.GetMediaItemTake_Track(take) end
  return reaper.GetSelectedTrack(0, 0)
end

local function context_notice(take, track)
  if not track then return NO_TRACK_NOTICE end
  if not take then return PREVIEW_ONLY end
  return EDITING
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

-- The Part the panel is actually editing, 1..16, or nil with no editor.
--
-- The dropdown outranks the piano roll once the user has used it, because
-- REAPER has no setter for default_note_chan: a pick that deferred to the
-- roll could never take effect. Until then the roll leads, so the tool opens
-- on whatever channel the user was already looking at.
--
-- `rolled` is the last roll channel seen. Comparing against it rather than
-- against the override is what keeps the latch one-way: the roll moving on
-- its own must not look like a reason to drop the user's pick.
local override, rolled = nil, nil

local function visible_part(ed)
  local roll = active_part(ed)
  -- With no MIDI editor there is no roll to follow, so the dropdown is the
  -- only source there is -- and it must still name a Part, because previewing
  -- needs a channel and a track is enough to preview. Defaulting to 1 is what
  -- makes the panel usable with nothing but a track selected.
  if not roll then return override or 1 end
  if roll ~= rolled then
    -- The roll moved. Before the user has picked, follow it; after, ignore
    -- it but keep tracking where it is so the next move is still detectable.
    rolled = roll
    if not override then return roll end
  end
  return override or roll
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
  if rule == 'enum' then
    return p.choices[math.floor(v) - p.min + 1] or tostring(v)
  end
  if rule == 'note' then
    -- The manual's naming: 0 is C-1, 60 is C4, 127 is G9.
    local n = math.floor(v)
    local name = ('C C#D D#E F F#G G#A A#B '):sub(n % 12 * 2 + 1, n % 12 * 2 + 2)
    return name:gsub(' ', '') .. (n // 12 - 1)
  end
  if rule == 'pan' then
    if v == 0 then return 'C' end
    if v < 0 then return ('L%d'):format(-v) end
    return ('R%d'):format(v)
  end
  return ('%d'):format(v)
end

-- pending snapshot -------------------------------------------------------------------

-- Record the one parameter this channel has pending, replacing whatever was
-- there. Exactly one, by design: Insert writes one parameter and the footer
-- names it.
local function set_pending(part, id, value)
  channels[part].pending = { id = id, value = value }
end

-- A voice selection as this channel's one pending edit.
--
-- Shaped differently from a parameter's snapshot -- a voice is an address,
-- not a value in a range -- but it occupies the same single slot, so the
-- one-pending-edit rule still holds: choosing a voice replaces a pending
-- parameter edit and vice versa, and Insert always has exactly one thing to
-- write.
local function set_pending_voice(part, msb, lsb, pc, shown)
  channels[part].pending =
    { voice = { msb = msb, lsb = lsb, pc = pc }, shown = shown }
end

-- Every channel holding a pending edit, lowest Part first.
--
-- The Overview edits all sixteen Parts, so "is there anything to insert"
-- cannot be answered by looking at one channel there -- an edit made on row
-- 9 belongs to Part 9 whatever the header says.
local function pending_parts()
  local out = {}
  for i = 1, 16 do
    if channels[i] and channels[i].pending then out[#out + 1] = i end
  end
  return out
end

local function pending_text(part)
  local pend = channels[part] and channels[part].pending
  if not pend then return '' end
  if pend.voice then
    return ('Pending: Voice %s'):format(pend.shown)
  end
  local p = P.BY_ID[pend.id]
  return ('Pending: %s %s'):format(p.name, display_value(p, pend.value))
end

-- preview -------------------------------------------------------------------------

-- Send one settled edit to the hardware. Never writes the take.
--
-- A routing failure is reported but does NOT discard the edit: the value
-- stays on screen and stays pending, so the user can fix the route or simply
-- insert it anyway.
-- The preview queue's key for one logical target.
--
-- The queue pairs this with the resolved output device and treats that pair
-- as the identity of a pending edit, so the key has to name everything that
-- makes the target distinct. A bare parameter id did not: an edit on Part 2
-- replaced Part 1's unsent edit to the same control, because both keys were
-- simply 'cutoff'.
--
-- A drum control is keyed by its MAP, note and parameter instead -- a drum
-- value belongs to the map and no Part appears in its identity at all.
local function part_key(part, id)
  return ('part:%d:%s'):format(part, id)
end

local function preview(track, part, id, value)
  local ch = channels[part]
  local ok, events = pcall(PM.encode, id, value, part, ch.use_sysex)
  if not ok then return set_status('ERROR: ' .. tostring(events)) end

  -- No route at all: the value is already pending and insertable, so this
  -- reports rather than failing. `{ track = nil }` is an EMPTY table, which
  -- would fall through to the take-based route and report the wrong reason.
  if not track then
    return set_status(HardwareOutput.NO_TRACK .. ' Value kept and still insertable.')
  end

  local sent, err = hw:preview_events(events, { track = track },
                                      part_key(part, id))
  if not sent then
    set_status(err .. ' Value kept and still insertable.')
  else
    set_status('')
  end
end

-- Handle one settled edit: it becomes this channel's sole pending snapshot
-- and previews on the hardware.
local function commit(track, part, id, value)
  set_pending(part, id, value)
  preview(track, part, id, value)
end

-- The name of the voice a Part is currently set to.
--
-- Read from the .reabank maps through voices.lua. An address the map does
-- not name is shown as its numbers rather than as nothing: the SC-8850's
-- banks are sparse, and a Part parked on an empty slot is a real state the
-- user needs to be able to see and correct.
-- Whether a Part draws its voices from the drum map.
--
-- Derived from Use For Rhythm rather than stored beside the voice, because
-- two copies of one fact drift: setting a Part to DRUM 2 left its picker
-- still browsing melodic instruments, since only choosing a voice ever wrote
-- the old duplicate.
local function is_drum(part)
  return channels[part].values.rhythm ~= 0
end

-- The two drum kits, one per Part Mode.
--
-- The kit belongs to the MODE, not to the Part. The manual is explicit: "the
-- same Drum Set will automatically be selected for Parts that have the same
-- Part Mode... if the Part Mode of both Parts 10 and 11 were set to Drum1,
-- selecting STANDARD1 for Part 10 would automatically select STANDARD1 for
-- Part 11 as well" (p.55).
--
-- So any number of Parts may be drum Parts, but only two kits can sound at
-- once -- there are two slots, not two drum Parts. Holding one voice per
-- Part would let the editor show two DRUM 1 Parts on different kits, which
-- the hardware cannot do: it would apply whichever was sent last to both.
--
-- Indexed by the rhythm value, 1 and 2.
local drum_kits = {}

local function reset_drum_kits()
  drum_kits = {}
  for mode = 1, 2 do
    drum_kits[mode] = { msb = Voices.DEFAULT_MSB, lsb = Voices.DEFAULT_LSB,
                        pc = Voices.DEFAULT_PC }
  end
end

reset_drum_kits()

-- The two drum CONTROL maps, one per Part Mode.
--
-- Same ownership as drum_kits above and for the same reason: a per-note drum
-- value belongs to the MAP, not to a Part. Every Part set to DRUM 1 sees one
-- DRUM 1 map and every Part set to DRUM 2 sees another, so the identity of a
-- value is (map, note, parameter) and a Part is nowhere in it. Putting these
-- inside channels[part] would let two Parts on one map show contradictory
-- state that the hardware cannot hold.
--
-- Each map owns:
--   selected_note  which note the panel is showing, 0..127
--   notes          a SPARSE table keyed by note number. A note is created the
--                  first time it is looked at, from the one seed function --
--                  128 notes x 9 parameters x 2 maps is 2304 values, nearly
--                  all of them untouched, and saving only what exists keeps
--                  the session record proportional to what the user did.
--   pending        transient pending edits keyed by note, one per note, never
--                  persisted -- the Drum Overview edits many notes at once,
--                  exactly as the Overview edits many Parts
local drum_maps = {}

local function reset_drum_maps()
  drum_maps = {}
  for mode = 1, 2 do
    drum_maps[mode] = { selected_note = 0, notes = {}, pending = {} }
  end
end

reset_drum_maps()

-- The shared value table for one note of one map, created from the seed on
-- first sight.
--
-- Every UI, preview, capture and restore path goes through this rather than
-- reaching into `notes` directly: one place decides what an unseen note
-- starts at, and one place validates the coordinates. Returns nil for an
-- invalid map or note rather than creating a phantom entry under a bad key.
-- The kit a drum map is currently playing: its program change, and the Bank
-- LSB naming the instrument map that program change is read against.
--
-- Both are needed, because a kit is (map, program change) and not a program
-- change alone -- PC 0 is STANDARD on the SC-55 and a different STANDARD 1 on
-- the SC-8850. Selecting a voice from another map moves the Part to it, which
-- is why the LSB is read here rather than assumed.
--
-- Read from the shared kit rather than stored beside the values, because two
-- copies of one fact drift -- the same reason is_drum derives from `rhythm`
-- rather than from a duplicate flag.
local function drum_kit_of(mode)
  local kit = drum_kits[mode]
  if not kit then return nil, nil end
  return kit.pc, kit.lsb
end

local function drum_note(mode, note)
  if not (D.valid_mode(mode) and D.valid_note(note)) then return nil end
  local map = drum_maps[mode]
  local values = map.notes[note]
  if not values then
    -- Seeded from the kit this map is on, so a note opens on the SC-8850's
    -- own value for that instrument rather than on one flat guess. The kit
    -- matters: Concert Snare ships with Reverb 50 and MC-500 Beep 1 with
    -- Reverb 0 and Pitch +12.
    values = D.seed_values(note, drum_kit_of(mode))
    map.notes[note] = values
  end
  return values
end

-- Which drum map a Part's controls belong to, or nil for a normal tone Part.
--
-- `rhythm` is the Use For Rhythm row: 0 is None, 1 is DRUM 1, 2 is DRUM 2 --
-- which is already the map number, so no second mapping is needed.
local function drum_mode_of(part)
  local mode = channels[part] and channels[part].values.rhythm
  if D.valid_mode(mode) then return mode end
  return nil
end

-- The map whose values the panel DISPLAYS for a Part.
--
-- A normal tone Part has no drum target, but the panel still draws the
-- complete set of controls greyed out rather than showing an empty tab. It
-- borrows DRUM 1's current values as an inert display source: a third
-- pseudo-map would be a third thing to keep in step, and mutating either real
-- map merely because a disabled panel was drawn would be a change the user
-- never made.
local function drum_display_mode(part)
  return drum_mode_of(part) or 1
end
local function voice_of(part)
  local mode = channels[part].values.rhythm
  if mode ~= 0 then return drum_kits[mode] end
  return channels[part].voice
end

-- Every Part that would follow a kit change on this one, itself included.
-- A melodic Part answers only for itself.
local function parts_sharing_voice(part)
  local mode = channels[part].values.rhythm
  if mode == 0 then return { part } end

  local out = {}
  for i = 1, 16 do
    if channels[i].values.rhythm == mode then out[#out + 1] = i end
  end
  return out
end

local function voice_name(part)
  local v = voice_of(part)
  return Voices.name(is_drum(part), v.msb, v.lsb, v.pc)
      or ('%d:%d:%d'):format(v.msb, v.lsb, v.pc)
end

-- Select a voice on one Part: preview it, and make it this channel's one
-- pending edit so Insert can write it.
--
-- The two halves are independent, as everywhere else in this tool -- a
-- preview that could not be routed still leaves a voice that can be
-- inserted, which is why the pending snapshot is set before the route is
-- even looked at.
local function select_voice(track, part, msb, lsb, pc)
  -- Written to whichever store this Part draws from: the shared kit for a
  -- drum Part, its own voice otherwise. One write, so every Part on the same
  -- drum mode follows automatically -- which is what the hardware does.
  local v = voice_of(part)
  local was_pc, was_lsb = v.pc, v.lsb
  v.msb, v.lsb, v.pc = msb, lsb, pc

  -- Changing a drum kit discards that map's per-note values, because the
  -- hardware does: "When the Drum Set is changed, DRUM SETUP PARAMETER
  -- values will all be initialized" (manual p.240). Keeping the old kit's
  -- edits on screen would show state the device no longer holds.
  --
  -- The notes are dropped rather than re-seeded here: drum_note seeds each
  -- one from the new kit the next time it is looked at, so one function
  -- still decides what an unseen note starts at.
  -- A kit is (map, program change), so moving to another INSTRUMENT MAP is
  -- as much a kit change as moving to another program change in the same
  -- one -- SC-55 STANDARD and SC-8850 STANDARD 1 are different kits with
  -- different per-note values.
  local mode = drum_mode_of(part)
  if mode and (pc ~= was_pc or lsb ~= was_lsb) then
    drum_maps[mode].notes = {}
    -- The pending edit described a value on the old kit, so it goes too --
    -- inserting it now would write a number the user chose for a kit that is
    -- no longer selected.
    drum_maps[mode].pending = {}
  end

  -- Every Part this change reaches. A kit change is a real change on each of
  -- them, so each gets its own pending edit and its own preview: the take
  -- needs one program change per channel, not one for the Part that happened
  -- to be clicked.
  local following = parts_sharing_voice(part)
  local shown = voice_name(part)
  for _, target in ipairs(following) do
    set_pending_voice(target, msb, lsb, pc, shown)
  end

  -- Pending above, so a missing route costs the preview and not the edit --
  -- the same split every parameter follows.
  if not track then
    return set_status(HardwareOutput.NO_TRACK .. ' Voice kept and still insertable.')
  end

  for _, target in ipairs(following) do
    local ok, events = pcall(PM.voice_events, target, msb, lsb, pc)
    if not ok then return set_status('ERROR: ' .. tostring(events)) end

    -- Addressed by part rather than by parameter id, so a voice change
    -- coalesces against an earlier voice change on the same Part and not
    -- against a parameter edit. Same shape as every other Part key, so a
    -- voice and a parameter can never collide on one Part either.
    local sent, err = hw:preview_events(events, { track = track },
                                        part_key(target, 'voice'))
    if not sent then return set_status(err) end
  end

  if #following > 1 then
    set_status(('%s on %d Parts'):format(shown, #following))
  else
    set_status(('Part %d: %s'):format(part, shown))
  end
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

  if pend.voice then
    local v = pend.voice
    local ok, err = inserter:insert_voice(take, part, v.msb, v.lsb, v.pc,
                                          pend.shown)
    if not ok then
      return set_status('Insert failed: ' .. tostring(err))
    end
    ch.pending = nil
    return set_status(('Inserted Voice %s'):format(pend.shown))
  end

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

-- drum controls --------------------------------------------------------------------

-- A drum value as the panel shows it. Numbers only, per the design: no note
-- names, no instrument names, no preset data. Pan therefore reads as its
-- canonical -64..63 rather than as L/C/R, because -64 is the hardware's
-- Random setting and calling that "L64" would name it something it is not.
local function drum_display(p, v)
  if p.display == D.SWITCH then return v >= 1 and 'On' or 'Off' end
  return ('%d'):format(v)
end

-- One map's pending edits, in note order.
local function drum_pending_list(mode)
  local out = {}
  local pending = drum_maps[mode] and drum_maps[mode].pending or {}
  for _, pend in pairs(pending) do out[#out + 1] = pend end
  table.sort(out, function(a, b) return a.note < b.note end)
  return out
end

-- What the footer says a map has pending.
local function drum_pending_text(mode)
  local list = drum_pending_list(mode)
  if #list == 0 then return '' end
  if #list > 1 then
    return ('Pending: Drum %d, %d notes'):format(mode, #list)
  end
  local pend = list[1]
  local p = D.BY_ID[pend.id]
  return ('Pending: Drum %d Note %d %s %s')
    :format(pend.mode, pend.note, p.name, drum_display(p, pend.value))
end

-- Record the one edit this NOTE has pending, replacing whatever was there.
--
-- One per note, the drum counterpart of one per Part: a second control on the
-- same note replaces it, while another note keeps its own -- which is what
-- lets the Drum Overview edit across rows and Insert write them all. The two
-- maps each keep their own, so switching Parts between a DRUM 1 Part and a
-- DRUM 2 Part does not discard either.
--
-- The note and map travel WITH the snapshot rather than being read back from
-- the panel at Insert time: the user may have moved the note selector or
-- switched Parts since, and Insert must write the edit that was actually
-- made.
local function set_drum_pending(mode, note, id, value)
  drum_maps[mode].pending[note] =
    { id = id, value = value, mode = mode, note = note }
end

-- Send one settled drum edit to the hardware. Never writes the take.
--
-- A routing failure is reported but does NOT discard the edit: the value
-- stays on screen and stays pending, so the user can fix the route or simply
-- insert it anyway -- the same split every Part control follows.
local function drum_preview(track, mode, note, id, value)
  local ok, events = pcall(DM.encode, id, value, mode, note)
  if not ok then return set_status('ERROR: ' .. tostring(events)) end

  if not track then
    return set_status(HardwareOutput.NO_TRACK .. ' Value kept and still insertable.')
  end

  -- Keyed by map, note and parameter -- never by Part, which is not part of a
  -- drum value's identity. The queue pairs this with the resolved device, so
  -- two notes, two maps or two controls never discard one another.
  local key = ('drum:%d:%d:%s'):format(mode, note, id)
  local sent, err = hw:preview_events(events, { track = track }, key)
  if not sent then
    set_status(err .. ' Value kept and still insertable.')
  else
    set_status('')
  end
end

-- Handle one settled drum edit: it becomes this MAP's sole pending snapshot
-- and previews on the hardware.
--
-- Pending first, preview second, exactly as commit() does for a Part: an
-- absent route must cost the preview and not the edit, or Insert would stay
-- disabled on a track with no hardware output.
local function drum_commit(track, mode, note, id, value)
  set_drum_pending(mode, note, id, value)
  drum_preview(track, mode, note, id, value)
end

-- Write every pending edit on one map at the edit cursor, in note order.
--
-- Each success clears that note's snapshot and only that one; the first
-- failure stops and keeps it and everything after it, so the user can
-- correct the context and retry. Nothing is previewed here -- Insert never
-- sends a second copy of what the user already heard.
local function insert_drum_pending(take, mode)
  local map = drum_maps[mode]
  local list = drum_pending_list(mode)
  if #list == 0 then return set_status('Nothing pending to insert.') end

  for _, pend in ipairs(list) do
    local p = D.BY_ID[pend.id]
    local shown = drum_display(p, pend.value)
    local ok, err = inserter:insert_drum(take, pend.mode, pend.note, pend.id,
                                         pend.value, shown)
    if not ok then
      return set_status('Insert failed: ' .. tostring(err))
    end
    map.pending[pend.note] = nil
    set_status(('Inserted Drum %d Note %d %s %s')
      :format(pend.mode, pend.note, p.name, shown))
  end
  if #list > 1 then
    set_status(('Inserted Drum %d, %d notes'):format(mode, #list))
  end
end

-- imgui scopes -------------------------------------------------------------------

-- The scopes the frame currently has open, innermost last.
--
-- ImGui's own stack is not inspectable from Lua, and it is strict about the
-- order things close in: a child inside a tab bar must be ended before the
-- tab bar, and ending them out of order raises an error ABOUT THE RECOVERY
-- ("Missing EndTabBar()") while the error that actually threw is lost.
--
-- Counting children alone is not enough, because children are not the only
-- scope: the panel nests body child > tab bar > tab item > rows child. The
-- unwind therefore records every scope and closes them in reverse, which is
-- the only order ImGui accepts.
local open_scopes = {}

local function push_scope(kind)
  open_scopes[#open_scopes + 1] = kind
end

local function pop_scope(kind)
  local top = open_scopes[#open_scopes]
  assert(top == kind, 'scope closed out of order: ' .. tostring(kind) ..
                      ' while ' .. tostring(top) .. ' is open')
  open_scopes[#open_scopes] = nil
end

-- How each scope is closed. Keyed by the same name push_scope records, so a
-- new scope type is added in one place.
local CLOSE = {
  child    = function() ImGui.EndChild(ctx) end,
  tab_bar  = function() ImGui.EndTabBar(ctx) end,
  tab_item = function() ImGui.EndTabItem(ctx) end,
  disabled = function() ImGui.EndDisabled(ctx) end,
  table    = function() ImGui.EndTable(ctx) end,
  popup    = function() ImGui.EndPopup(ctx) end,
}

-- flags defaults to ChildFlags_None: no ResizeX, so a divider is not a drag
-- handle. false means collapsed or fully clipped and the binding has already
-- ended the child itself, so nothing is recorded in that case.
local function begin_child(id, w, h, flags)
  if not ImGui.BeginChild(ctx, id, w, h, flags or ImGui.ChildFlags_None) then
    return false
  end
  push_scope('child')
  return true
end

local function end_child()
  ImGui.EndChild(ctx)
  pop_scope('child')
end

local function begin_tab_bar(id)
  if not ImGui.BeginTabBar(ctx, id) then return false end
  push_scope('tab_bar')
  return true
end

local function end_tab_bar()
  ImGui.EndTabBar(ctx)
  pop_scope('tab_bar')
end

local function begin_tab_item(label, flags)
  if not ImGui.BeginTabItem(ctx, label, nil, flags) then return false end
  push_scope('tab_item')
  return true
end

local function end_tab_item()
  ImGui.EndTabItem(ctx)
  pop_scope('tab_item')
end

local function begin_table(id, cols, flags)
  if not ImGui.BeginTable(ctx, id, cols, flags) then return false end
  push_scope('table')
  return true
end

local function end_table()
  ImGui.EndTable(ctx)
  pop_scope('table')
end

local function begin_popup(id)
  if not ImGui.BeginPopup(ctx, id) then return false end
  push_scope('popup')
  return true
end

local function end_popup()
  ImGui.EndPopup(ctx)
  pop_scope('popup')
end

local function begin_disabled()
  ImGui.BeginDisabled(ctx, true)
  push_scope('disabled')
end

local function end_disabled()
  ImGui.EndDisabled(ctx)
  pop_scope('disabled')
end

-- Close whatever the frame left open, innermost first. Called only on the
-- error path; a frame that returns normally has already emptied the stack.
local function unwind_scopes()
  for i = #open_scopes, 1, -1 do
    CLOSE[open_scopes[i]]()
    open_scopes[i] = nil
  end
end

-- An enum row's choices as ImGui wants them: one string of null-terminated
-- names, plus its byte length. Built once per row and cached, since a row's
-- choices never change.
local enum_cache = {}

local function enum_entry(p)
  local entry = enum_cache[p.id]
  if not entry then
    local items = table.concat(p.choices, '\0') .. '\0'
    entry = { items = items, size = #items }
    enum_cache[p.id] = entry
  end
  return entry
end

local function enum_items(p) return enum_entry(p).items end
local function enum_items_sz(p) return enum_entry(p).size end

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
-- `key` distinguishes two widgets editing the same parameter. The per-part
-- pages draw each parameter once and pass nothing, so the parameter id is
-- the key; the Overview draws every parameter on sixteen rows and passes a
-- per-row key, without which a double-click reset on one row would reset
-- that parameter on all sixteen.
-- `values` is the table the widget edits and `reset_to` what a double-click
-- returns to. The Part rows pass their channel's values and the row's own
-- documented default; the Drum rows pass a shared map's note table and that
-- note's seed, since a drum row has no power-on default to return to -- there
-- is no factory-data source in the editor to name one.
local function settled(p, values, reset_to, key)
  key = key or p.id
  local send = ImGui.IsItemDeactivatedAfterEdit(ctx)
  if ImGui.IsItemHovered(ctx)
     and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
    resetting[key] = true
  end
  if resetting[key] then
    values[p.id] = reset_to
    if ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left) then
      send = false
    else
      resetting[key] = nil
    end
  end
  return send
end

-- One control row. Returns true on the frame its value settled.
--
-- Laid out the way the XG editor lays a row out: the label right-aligned
-- against a fixed column so every slider starts at one x, the slider next,
-- and the value as plain text after it rather than printed on the grab.
--
-- The label is right-aligned by measuring it and setting the cursor, because
-- ImGui has no alignment for Text: it draws from the cursor and that is the
-- only handle there is.
local function control_row(p, part, label_w, field_w)
  local ch = channels[part]
  local v = ch.values[p.id]

  local tw = ImGui.CalcTextSize(ctx, p.name)
  local x, y = ImGui.GetCursorPos(ctx)
  ImGui.SetCursorPos(ctx, x + math.max(0, label_w - tw), y)
  -- AlignTextToFramePadding: the label sits beside a framed widget, so its
  -- baseline has to drop by the frame's padding or it rides high on the row.
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, p.name)
  ImGui.SameLine(ctx, 0, LABEL_GAP)
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

  if p.display == 'enum' then
    -- Named states, not a range: a slider between None, DRUM 1 and DRUM 2
    -- would invite dragging through a value that means something else. Like
    -- a checkbox, a combo commits on the click and has no settle to wait for.
    local changed, idx = ImGui.Combo(ctx, '##' .. p.id,
                                     math.floor(v) - p.min,
                                     enum_items(p), enum_items_sz(p))
    if changed then
      ch.values[p.id] = idx + p.min
      return true
    end
    return false
  end

  -- The slider carries no text of its own: ' ' rather than '' because an
  -- empty format still prints the raw number, and the value is drawn after
  -- the slider instead.
  local fmt = ' '

  local changed, nv
  if p.step and p.step < 1 then
    -- Tuning Offset is the one continuous control; everything else is whole
    -- numbers and reads better as an integer slider.
    changed, nv = ImGui.SliderDouble(ctx, '##' .. p.id, v, p.min, p.max, fmt,
                                     ImGui.SliderFlags_ClampOnInput)
  else
    -- ClampOnInput: a value typed via Ctrl+Click is otherwise not clamped and
    -- can leave the parameter's documented range.
    changed, nv = ImGui.SliderInt(ctx, '##' .. p.id, math.floor(v),
                                  math.floor(p.min), math.floor(p.max), fmt,
                                  ImGui.SliderFlags_ClampOnInput)
  end
  if changed then ch.values[p.id] = nv end

  -- Settled BEFORE anything else is drawn.
  --
  -- IsItemDeactivatedAfterEdit, IsItemHovered and the rest all describe the
  -- LAST item drawn. Drawing the value text first would make them describe
  -- that text, which is never activated and never hovered for a drag -- so
  -- the slider would never settle, never commit, and Insert would never
  -- leave its disabled state.
  local send = settled(p, ch.values, P.default_for(p, part))

  -- The value, after the slider. Read from the table rather than from `nv`,
  -- so the frame a double-click resets the control shows the default rather
  -- than the value the click dragged it to first.
  ImGui.SameLine(ctx, 0, LABEL_GAP)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, display_value(p, ch.values[p.id]))

  return send
end

-- One drum control row. Returns true on the frame its value settled.
--
-- Laid out exactly as control_row lays a Part row out -- right-aligned label,
-- slider, value text -- and sharing the same settle and double-click
-- implementation. What differs is only where the value lives: a shared map's
-- note table rather than a channel's, and a seed rather than a documented
-- default to reset to.
--
-- `key` carries the map, the note and the parameter. Without the note in it,
-- a double-click gesture begun on one note would go on resetting whatever
-- note the combo moved to, and ImGui would treat two notes' sliders as one
-- widget -- dragging either would move whichever drew first.
--
-- `kit` and `bank` are the drum map's current program change and Bank LSB,
-- and together decide what a double-click resets to: the factory value for
-- this instrument on this kit of this instrument map.
local function drum_row(p, mode, note, kit, bank, values, label_w, field_w)
  local key = ('drum-%d-%d-%s'):format(mode, note, p.id)
  local v = values[p.id]

  local tw = ImGui.CalcTextSize(ctx, p.name)
  local x, y = ImGui.GetCursorPos(ctx)
  ImGui.SetCursorPos(ctx, x + math.max(0, label_w - tw), y)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, p.name)
  ImGui.SameLine(ctx, 0, LABEL_GAP)
  ImGui.SetNextItemWidth(ctx, field_w)

  if p.display == D.SWITCH then
    -- A switch has no settle to wait for: a checkbox commits on the click.
    local changed, on = ImGui.Checkbox(ctx, '##' .. key, v >= 1)
    if changed then
      values[p.id] = on and 1 or 0
      return true
    end
    return false
  end

  -- The slider carries no text of its own: ' ' rather than '' because an
  -- empty format still prints the raw number, and the value is drawn after
  -- the slider instead.
  --
  -- ClampOnInput: a value typed via Ctrl+Click is otherwise not clamped and
  -- can leave the parameter's documented range -- which the encoder would
  -- then reject rather than send.
  local changed, nv = ImGui.SliderInt(ctx, '##' .. key, math.floor(v),
                                      math.floor(p.min), math.floor(p.max),
                                      ' ', ImGui.SliderFlags_ClampOnInput)
  if changed then values[p.id] = nv end

  -- Settled BEFORE anything else is drawn. IsItemDeactivatedAfterEdit and the
  -- rest all describe the LAST item drawn, so the value text below must come
  -- after this or the slider would never settle and Insert would never leave
  -- its disabled state.
  --
  -- A double-click returns to the SC-8850's own factory value for this
  -- instrument on this kit -- the same value the note opened on. Reset is a
  -- real "back to how it shipped" for every note the factory table covers.
  local send = settled(p, values, D.seed_values(note, kit, bank)[p.id], key)

  ImGui.SameLine(ctx, 0, LABEL_GAP)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, drum_display(p, values[p.id]))

  return send
end

-- The note selector's items: 0 through 127 as plain numbers, one string of
-- null-terminated entries plus its byte length.
--
-- Numbers only, by design: no note names, no percussion names, no preset
-- dataset. The selected index IS the MIDI note number, which is what keeps
-- the combo and the third address byte from ever disagreeing.
--
-- Built once and cached. ReaImGui 0.10's Combo splits the list by the length
-- it is given rather than stopping at the first NUL, so passing the size is
-- not optional -- without it the list is one empty entry.
local NOTE_ITEMS = (function()
  local t = {}
  for n = 0, 127 do t[n + 1] = tostring(n) end
  return table.concat(t, '\0') .. '\0'
end)()
local NOTE_ITEMS_SZ = #NOTE_ITEMS

-- The dropdown's items: one string of null-terminated names, plus its byte
-- length. Combo splits the list by that length rather than stopping at the
-- first NUL, so the size is not optional -- passing only the string would
-- yield a single empty entry.
--
-- Built once rather than per frame, since the sixteen channels never change.
local CHANNEL_ITEMS = (function()
  local t = {}
  for i = 1, 16 do t[i] = ('Channel %d'):format(i) end
  return table.concat(t, '\0') .. '\0'
end)()
local CHANNEL_ITEMS_SZ = #CHANNEL_ITEMS

-- What the picker shows on the Overview, where no one channel is being
-- edited. Same one-string-plus-length shape as the channel list.
local MULTI_ITEM = 'Multi\0'
local MULTI_ITEM_SZ = #MULTI_ITEM

-- Whether the Overview tab is the one showing.
--
-- The Overview edits all sixteen Parts at once, so the channel picker has no
-- single Part to name there and says Multi instead, locked. Per-visit UI
-- state like `page`, and not saved.
local OVERVIEW_TAB = 'Overview'
local showing_overview = false

-- Whether the Drum Controls tab is the one showing.
--
-- Recorded the same one-frame-late way as showing_overview, and for the same
-- reason: the header and footer draw outside the tab bar and so cannot ask
-- which tab is open. What it decides is what Insert targets, and that `Use
-- SysEx?` is inert -- drum encoding is always DT1, so the checkbox governs
-- nothing while this tab is up.
local DRUM_TAB = 'Drum Controls'
local showing_drum = false

-- The Drum Overview: every note of the map at once. It counts as a drum tab
-- for everything showing_drum decides -- Insert target, Use SysEx? -- so it
-- sets that flag too rather than adding a second one to keep in step.
local DRUM_OVERVIEW_TAB = 'Drum Overview'

-- Set when a note number is clicked on the Drum Overview: the next Drum
-- Controls tab submission selects itself, showing that note.
local jump_to_drum = false

-- The Overview's counterpart: a clicked Part number latches that channel,
-- exactly as the header picker does, and Part Controls selects itself.
local jump_to_part = false

-- The header channel picker. Selecting latches the override, so from here on
-- the piano roll no longer moves the panel.
--
-- Gated on the route rather than on the Part: without a track nothing can be
-- previewed, so choosing a channel would change nothing audible. With a track
-- it is live whether or not a MIDI editor is open -- that is the whole point
-- of the track-only mode.
local function channel_picker(part, track, em)
  -- On the Overview every Part is being edited at once, so there is no one
  -- channel to name and nothing a pick could mean: the control says Multi
  -- and is locked. A combo is kept rather than swapped for text so the
  -- header does not change shape between tabs.
  local locked = showing_overview
  if locked or not track then begin_disabled() end
  ImGui.SetNextItemWidth(ctx, em * 10)
  local changed, idx
  if locked then
    changed, idx = ImGui.Combo(ctx, '##channel', 0, MULTI_ITEM, MULTI_ITEM_SZ)
  else
    changed, idx = ImGui.Combo(ctx, '##channel', part - 1,
                               CHANNEL_ITEMS, CHANNEL_ITEMS_SZ)
  end
  if changed and track and not locked then
    override = idx + 1
    -- Switching channel shows a different set of values and sends nothing,
    -- exactly as the per-channel state contract says.
    set_status('')
  end
  if locked or not track then end_disabled() end
end

-- panel -------------------------------------------------------------------------

-- The sidebar pages, in sidebar order. Each names the groups it shows, so a
-- page is a view over part_params.lua rather than a second list of controls:
-- a parameter added there appears here by virtue of its group.
--
-- The names are the groups' own, not the XG editor's -- the layout is being
-- matched, not the SC-8850's parameter set. Every group appears on exactly
-- one page, which the tests assert, because a group listed on none would
-- simply never be drawn and nothing else would notice.
-- The Overview grid's columns, left to right.
--
-- The XG panel's grid, mapped onto what the SC-8850 actually has: its Var
-- and Dry columns are dropped (GS has no variation send and no dry level)
-- and Delay takes the third send slot, which is the 8850's own third effect.
--
-- Each entry names a parameter id from part_params.lua, so a column is a
-- view over the same rows the per-part pages draw -- there is no second
-- definition of what Cutoff means.
local GRID_COLUMNS = {
  -- Which drum map the Part plays, if any. First because it decides what
  -- every other column on the row means: a drum Part's voice comes from a
  -- different map entirely.
  { id = 'rhythm',    label = 'Rhythm' },
  { id = 'mono_poly', label = 'M/P' },
  { id = 'cutoff',    label = 'Cut' },
  { id = 'resonance', label = 'Res' },
  { id = 'attack',    label = 'Atk' },
  { id = 'decay',     label = 'Dec' },
  { id = 'release',   label = 'Rls' },
  { id = 'reverb',    label = 'Rev' },
  { id = 'chorus',    label = 'Cho' },
  { id = 'delay',     label = 'Dly' },
  { id = 'pan',       label = 'Pan' },
  { id = 'level',     label = 'Level' },
}

local PAGES = {
  { name = 'Common', groups = { 'Sends and Mix', 'Switches and Performance' } },
  { name = 'Filter', groups = { 'Filter', 'Envelope' } },
  { name = 'Tuning', groups = { 'Tuning', 'Scale Tuning' } },
  { name = 'Vibrato', groups = { 'Vibrato' } },
  { name = 'Keyboard', groups = { 'Keyboard' } },
  { name = 'Receive', groups = { 'Receive' } },
  -- One grid rather than a page per source: `matrix` draws these groups as
  -- destinations down, sources across (draw_matrix).
  { name = 'Controllers', matrix = true,
    groups = { 'Mod Wheel', 'Pitch Bend', 'Channel Aftertouch',
               'Poly Aftertouch', 'CC1', 'CC2' } },
}

-- Which sidebar page is showing. Per-visit UI state, not per-channel and not
-- saved: switching channel must not move the user off the page they are on.
local page = 1

-- The label column, measured rather than guessed: the longest name on the
-- page decides where every slider starts, so nothing is clipped and the
-- sliders still line up. XG picks one column width for the whole editor; this
-- picks one per page, which keeps a page of short names from being pushed
-- right by a long name the user cannot see.
local function label_column(groups)
  local w = 0
  for _, group in ipairs(groups) do
    for _, prm in ipairs(P.PARAMS) do
      if prm.group == group then
        -- Parenthesised: CalcTextSize returns width AND height, and as the
        -- last argument both would expand into math.max -- which would let a
        -- text height win the column whenever it exceeds every width.
        w = math.max(w, (ImGui.CalcTextSize(ctx, prm.name)))
      end
    end
  end
  return w
end

-- Draw one page's rows, in one column.
--
-- Clusters are separated by blank space rather than by a named header, which
-- is the XG editor's grouping: the rows that belong together sit together and
-- nothing is labelled twice.
--
-- `part` is never nil now -- the dropdown always names a channel -- but a
-- commit still needs a route, so `track` is what gates the send.
local function draw_page(entry, track, part, field_w)
  local label_w = label_column(entry.groups)
  for i, group in ipairs(entry.groups) do
    if i > 1 then ImGui.Dummy(ctx, 0, CLUSTER_GAP) end
    for _, prm in ipairs(P.PARAMS) do
      if prm.group == group then
        -- Committed whether or not there is a route. The two halves are
        -- independent by design: a settled edit becomes this channel's
        -- pending snapshot so Insert can write it, and previews only if
        -- there is somewhere to send. Gating the commit on `track` left
        -- Insert permanently grey on a track with no hardware output.
        if control_row(prm, part, label_w, field_w) then
          commit(track, part, prm.id, channels[part].values[prm.id])
        end
      end
    end
  end
end

-- The Drum Controls page: a numeric note selector and the nine per-note
-- controls of one shared map.
--
-- `mode` is the map being DISPLAYED, which is the selected Part's map when it
-- has one and DRUM 1 otherwise. `editable` is false for a normal tone Part or
-- when there is no preview route: the complete panel is still drawn, greyed
-- out, rather than replaced by an empty tab or an explanation. A disabled
-- draw must not mutate either real map -- reading a note through drum_note
-- seeds it, which is a creation the user did not ask for on a map they are
-- not editing, so the seed is used directly in that case.
local function draw_drum_page(track, mode, editable, field_w)
  local map = drum_maps[mode]
  local note = map.selected_note

  -- The note selector. Choosing a note only changes what is DISPLAYED: it
  -- sends nothing, inserts nothing and creates no pending edit, exactly as
  -- switching channel does.
  local label_w = ImGui.CalcTextSize(ctx, 'Assign Group')
  do
    local tw = ImGui.CalcTextSize(ctx, 'Note')
    local x, y = ImGui.GetCursorPos(ctx)
    ImGui.SetCursorPos(ctx, x + math.max(0, label_w - tw), y)
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Note')
    ImGui.SameLine(ctx, 0, LABEL_GAP)
    ImGui.SetNextItemWidth(ctx, field_w)
    -- The index IS the note number, so no conversion sits between the combo
    -- and the address byte.
    local changed, idx = ImGui.Combo(ctx, '##drum-note', note,
                                     NOTE_ITEMS, NOTE_ITEMS_SZ)

    -- The wheel steps the note while the combo is hovered, without opening
    -- the list -- 128 entries is a long scroll otherwise, and stepping
    -- through neighbouring notes is how a drum kit is actually auditioned.
    --
    -- Asked IMMEDIATELY after the combo and before anything else is drawn:
    -- IsItemHovered describes the LAST item, so a query moved below the rows
    -- would report on whatever drew last and scroll the note from anywhere
    -- on the page.
    --
    -- Wheel up is the LOWER index, matching the Effects Editor's own type
    -- picker and every list in REAPER: up moves toward the top of the list.
    local wheel = 0
    if ImGui.IsItemHovered(ctx) then
      local w = ImGui.GetMouseWheel(ctx)
      if w ~= 0 then wheel = w > 0 and -1 or 1 end
    end

    if changed and editable then
      map.selected_note = idx
      note = idx
      set_status('')
    elseif wheel ~= 0 and editable then
      -- Clamped rather than wrapped: note 0 and note 127 are the ends of the
      -- range, and wrapping from one to the other would jump the panel across
      -- the whole kit on a single notch.
      local stepped = math.max(0, math.min(127, note + wheel))
      if stepped ~= note then
        map.selected_note = stepped
        note = stepped
        set_status('')
      end
    end
  end

  ImGui.Dummy(ctx, 0, CLUSTER_GAP)

  -- A disabled panel reads from the seed rather than from the map, so
  -- drawing it creates nothing. An editable one reads the shared table every
  -- Part on this map sees.
  -- `bank` is the Bank LSB naming the instrument map, not `map` above, which
  -- is this drum map's own state table.
  local kit, bank = drum_kit_of(mode)
  local values = editable and drum_note(mode, note)
                 or D.seed_values(note, kit, bank)
  local existing = map.notes[note]
  if not editable and existing then values = existing end

  for _, p in ipairs(D.PARAMS) do
    if drum_row(p, mode, note, kit, bank, values, label_w, field_w) and editable then
      drum_commit(track, mode, note, p.id, values[p.id])
    end
  end
end

-- Short column headers for the Drum Overview; anything absent uses its name.
local DRUM_GRID_LABELS = {
  assign_group = 'Assign', rx_note_on = 'Rx On', rx_note_off = 'Rx Off',
}

-- One Drum Overview cell: grid_cell's drum counterpart. Value drawn inside
-- the grab, same widget id as the Drum Controls row for the same note, so a
-- double-click reset and a drag behave identically on either tab.
--
-- `values` may be an unstored seed. The first change stores it on the map,
-- so an edited note persists while a note merely LOOKED AT on the grid does
-- not -- drawing forty rows must not fill the sparse table and the session
-- record with notes nobody touched.
local function drum_cell(p, mode, note, kit, bank, values, editable)
  local key = ('drum-%d-%d-%s'):format(mode, note, p.id)
  local id = '##' .. key
  local v = values[p.id]
  local function store()
    if editable and drum_maps[mode].notes[note] ~= values then
      drum_maps[mode].notes[note] = values
    end
  end

  ImGui.SetNextItemWidth(ctx, -1)
  if p.display == D.SWITCH then
    local changed, on = ImGui.Checkbox(ctx, id, v >= 1)
    if changed then
      values[p.id] = on and 1 or 0
      store()
      return true
    end
    return false
  end

  local changed, nv = ImGui.SliderInt(ctx, id, math.floor(v),
                                      math.floor(p.min), math.floor(p.max),
                                      '%d', ImGui.SliderFlags_ClampOnInput)
  if changed then
    values[p.id] = nv
    store()
  end
  -- Settled straight after the slider, before anything else draws.
  return settled(p, values, D.seed_values(note, kit, bank)[p.id], key)
end

-- The Drum Overview: every note of one map, one row each, the drum
-- counterpart of the Part Overview. Which map, and whether it is editable,
-- follow the same rule as the Drum Controls tab.
--
-- Rows are the notes the current kit defines, which is what GSAE's Drum
-- Window lists; a kit the factory tables do not cover shows all 128.
local function drum_overview(track, mode, editable, em)
  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg
              | ImGui.TableFlags_ScrollY | ImGui.TableFlags_Resizable
  if not begin_table('drum-overview', 1 + #D.PARAMS, flags) then return end

  ImGui.TableSetupScrollFreeze(ctx, 0, 1)
  ImGui.TableSetupColumn(ctx, 'Note', ImGui.TableColumnFlags_WidthFixed, em * 2.5)
  for _, p in ipairs(D.PARAMS) do
    ImGui.TableSetupColumn(ctx, DRUM_GRID_LABELS[p.id] or p.name,
                           ImGui.TableColumnFlags_WidthStretch)
  end
  ImGui.TableHeadersRow(ctx)

  local map = drum_maps[mode]
  local kit, bank = drum_kit_of(mode)
  local notes = D.kit_notes(kit, bank)
  if not notes then
    notes = {}
    for n = 0, 127 do notes[#notes + 1] = n end
  end

  for _, note in ipairs(notes) do
    ImGui.TableNextRow(ctx)
    ImGui.TableNextColumn(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    -- The note number opens that note on Drum Controls. Highlighted when it
    -- is the note Drum Controls is on, so the two tabs visibly agree.
    if ImGui.Selectable(ctx, ('%d##drum-row-%d'):format(note, note),
                        note == map.selected_note) and editable then
      map.selected_note = note
      jump_to_drum = true
    end

    local values = map.notes[note] or D.seed_values(note, kit, bank)
    for _, p in ipairs(D.PARAMS) do
      ImGui.TableNextColumn(ctx)
      if drum_cell(p, mode, note, kit, bank, values, editable) and editable then
        drum_commit(track, mode, note, p.id, values[p.id])
      end
    end
  end

  end_table()
end

-- A width in ems. The popup sizes itself in text units so it stays sensible
-- at any font size, the way every other measurement in this panel does.
local function em_width(n) return ImGui.GetFontSize(ctx) * n end

-- The voice picker's filter text, and which Part's popup is open.
--
-- One filter shared by all sixteen popups rather than one each: only one
-- popup can be open at a time, so a second copy would only ever hold a stale
-- search from a row the user has already left.
local voice_filter = ''

-- One Part's voice button. Opens a searchable list of every voice in the
-- map that Part draws from.
--
-- A flat combo is not usable here: the tone map holds over 1500 voices
-- across 51 banks, so the list is filtered by typing rather than scrolled.
-- Matching is case-insensitive and matches the bank name too, which is what
-- makes "vari" narrow to the variation banks.
local function voice_button(track, part, w)
  local id = 'voice-' .. part
  ImGui.SetNextItemWidth(ctx, w)

  if ImGui.Button(ctx, voice_name(part) .. '##' .. id, w, 0) then
    voice_filter = ''
    ImGui.OpenPopup(ctx, id)
  end

  if not begin_popup(id) then return end

  -- Focus the search box as the popup opens, so the user can type straight
  -- away rather than having to click into it first.
  if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
  ImGui.SetNextItemWidth(ctx, em_width(20))
  local changed, text = ImGui.InputTextWithHint(ctx, '##filter',
                                                'Search voices', voice_filter)
  -- Guarded: ImGui returns the buffer alongside the changed flag, and a
  -- filter that went nil would take down the frame on the next :lower().
  if changed and type(text) == 'string' then voice_filter = text end

  local needle = voice_filter:lower()
  local drum = is_drum(part)
  -- The shared kit for a drum Part, its own voice otherwise, so the tick
  -- marks the voice this Part is really on.
  local cur = voice_of(part)

  -- One voice row. Shown as its name plus the bank it came from, because the
  -- same name recurs across banks -- there are several Piano 1s, and the
  -- bank is the only thing that tells them apart.
  -- `map` is passed only by the flat search listing, which names the map on
  -- each hit because the same voice exists in several. Inside the tree the
  -- branch above already says which map this is.
  --
  -- The bank is shown only where the name alone would be ambiguous. Nearly
  -- every name is unique within its category, so printing "[Capital-Tones
  -- [SC8850]]" on all of them buries the names the user is reading for.
  local function voice_row(v, map)
    local bank = v.bank
    local suffix = ''
    if map then
      suffix = (' [%s]'):format(map.name)
    elseif v.ambiguous then
      suffix = (' [%s]'):format(bank.name)
    end
    local label = ('%s%s##%d-%d-%d')
      :format(v.name, suffix, bank.msb, bank.lsb, v.pc)
    local selected = cur.msb == bank.msb and cur.lsb == bank.lsb
                     and cur.pc == v.pc
    if ImGui.Selectable(ctx, label, selected) then
      -- The bank carries its own LSB, which is the map: selecting a voice
      -- from another map moves the Part to that map, as it must.
      select_voice(track, part, bank.msb, bank.lsb, v.pc)
      ImGui.CloseCurrentPopup(ctx)
    end
  end

  if begin_child('voice-list', em_width(22), em_width(16)) then
    if needle == '' then
      -- Map, then category, then voice. Two levels of tree because there are
      -- two real choices to make: which module's sound set to play, and what
      -- kind of instrument. Over three thousand voices across the four maps
      -- is far past what a flat list can offer.
      for _, map in ipairs(Voices.MAPS) do
        -- The map the Part is already on opens by default, so the tree lands
        -- on what is selected rather than fully closed.
        if map.lsb == cur.lsb then
          ImGui.SetNextItemOpen(ctx, true, ImGui.Cond_Once)
        end
        if ImGui.TreeNode(ctx, map.name) then
          for _, group in ipairs(Voices.by_category(drum, map.lsb)) do
            if ImGui.TreeNode(ctx, group.name .. '##' .. map.name) then
              for _, v in ipairs(group.voices) do voice_row(v) end
              ImGui.TreePop(ctx)
            end
          end
          ImGui.TreePop(ctx)
        end
      end
    else
      -- Searching: one flat list across every map, because a match inside a
      -- collapsed branch would be invisible, and the tree stops earning its
      -- space the moment the user has said what they want. The map is named
      -- on each hit, since the same voice exists in several.
      local hits = 0
      for _, map in ipairs(Voices.MAPS) do
        for _, group in ipairs(Voices.by_category(drum, map.lsb)) do
          for _, v in ipairs(group.voices) do
            if v.name:lower():find(needle, 1, true)
               or v.bank.name:lower():find(needle, 1, true) then
              voice_row(v, map)
              hits = hits + 1
            end
          end
        end
      end
      if hits == 0 then ImGui.Text(ctx, 'No voices match.') end
    end

    end_child()
  end

  end_popup()
end

-- One editable grid cell. Returns true on the frame its value settled.
--
-- A narrower control_row: no label and no value text, because the column
-- header names the parameter and the grid has no room to repeat it. The
-- settle rule is the same one the per-part pages use, so a drag in the grid
-- and a drag on a page reach the hardware identically.
--
-- The widget id carries the part as well as the parameter: sixteen rows draw
-- the same parameter, and ImGui would treat one id as one widget -- dragging
-- any row would move whichever row drew first.
local function grid_cell(prm, part, w)
  local ch = channels[part]
  local v = ch.values[prm.id]
  local id = ('##%s-%d'):format(prm.id, part)

  ImGui.SetNextItemWidth(ctx, w)

  if prm.display == 'switch' then
    local changed, on = ImGui.Checkbox(ctx, id, v >= 1)
    if changed then
      ch.values[prm.id] = on and 1 or 0
      return true
    end
    return false
  end

  if prm.display == 'enum' then
    local changed, idx = ImGui.Combo(ctx, id, math.floor(v) - prm.min,
                                     enum_items(prm), enum_items_sz(prm))
    if changed then
      ch.values[prm.id] = idx + prm.min
      return true
    end
    return false
  end

  -- The value is drawn INSIDE the grab here, unlike the per-part pages which
  -- have room for it beside the slider. A grid column is too narrow for a
  -- separate value cell, and a slider whose number is invisible until it is
  -- dragged says nothing about the Part it belongs to.
  --
  -- ImGui substitutes the value into %d/%f itself, so a rule that renders
  -- something other than the raw number has to pre-render it and escape any
  -- percent signs that produced.
  local fmt = prm.display == 'plain' and '%d'
           or (display_value(prm, v):gsub('%%', '%%%%'))

  local changed, nv
  if prm.step and prm.step < 1 then
    changed, nv = ImGui.SliderDouble(ctx, id, v, prm.min, prm.max,
                                     fmt, ImGui.SliderFlags_ClampOnInput)
  else
    changed, nv = ImGui.SliderInt(ctx, id, math.floor(v),
                                  math.floor(prm.min), math.floor(prm.max),
                                  fmt, ImGui.SliderFlags_ClampOnInput)
  end
  if changed then ch.values[prm.id] = nv end

  -- settled() keys its double-click state by parameter id alone, which would
  -- make a reset on one row reset that parameter on every row. The grid
  -- passes a per-row key so a double-click stays on the row it happened on.
  return settled(prm, ch.values, P.default_for(prm, part), id)
end

-- The Controllers page: GSAE's Controller Matrix for one Part. Destinations
-- down, the six sources across, every cell a grid_cell on its own row of
-- part_params.lua -- so a cell previews, goes pending and inserts exactly as
-- the same control would on a list page. The CC1/CC2 controller pickers sit
-- below, as they do in GSAE.
local function draw_matrix(track, part, em)
  local sources = P.CONTROLLER_SOURCES
  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg
  if begin_table('controller-matrix', 1 + #sources, flags) then
    ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed, em * 9)
    for _, src in ipairs(sources) do
      ImGui.TableSetupColumn(ctx, src.name, ImGui.TableColumnFlags_WidthStretch)
    end
    ImGui.TableHeadersRow(ctx)

    for _, dst in ipairs(P.CONTROLLER_DESTINATIONS) do
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, dst.name)
      for _, src in ipairs(sources) do
        ImGui.TableNextColumn(ctx)
        local prm = P.BY_ID[P.matrix_id(src.key, dst.key)]
        if grid_cell(prm, part, -1) then
          commit(track, part, prm.id, channels[part].values[prm.id])
        end
      end
    end
    end_table()
  end

  ImGui.Dummy(ctx, 0, CLUSTER_GAP)
  local pickers = { P.BY_ID.cc1_number, P.BY_ID.cc2_number }
  local label_w = ImGui.CalcTextSize(ctx, pickers[2].name)
  for _, prm in ipairs(pickers) do
    if control_row(prm, part, label_w, em * 12) then
      commit(track, part, prm.id, channels[part].values[prm.id])
    end
  end
end

-- The Overview: all sixteen Parts at once, one row each.
--
-- Editable, and by the same rules as everywhere else -- a settled cell
-- becomes that channel's pending snapshot and previews on the hardware. The
-- pending snapshot stays per-channel, so editing row 5 leaves row 3's
-- pending edit alone.
local function overview(track, current, em)
  -- Resizable so a long voice name can be given room; ScrollY so sixteen
  -- rows plus a header fit a short window without pushing the footer off.
  local flags = ImGui.TableFlags_Borders | ImGui.TableFlags_RowBg
              | ImGui.TableFlags_ScrollY | ImGui.TableFlags_Resizable
  if not begin_table('overview', 2 + #GRID_COLUMNS, flags) then return end

  -- The header row stays put while the rows scroll under it.
  ImGui.TableSetupScrollFreeze(ctx, 0, 1)
  ImGui.TableSetupColumn(ctx, 'Part', ImGui.TableColumnFlags_WidthFixed, em * 2.5)
  ImGui.TableSetupColumn(ctx, 'Voice', ImGui.TableColumnFlags_WidthFixed, em * 8)
  for _, col in ipairs(GRID_COLUMNS) do
    ImGui.TableSetupColumn(ctx, col.label, ImGui.TableColumnFlags_WidthStretch)
  end
  ImGui.TableHeadersRow(ctx)

  for part = 1, 16 do
    ImGui.TableNextRow(ctx)

    ImGui.TableNextColumn(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    -- The Part number opens that Part on Part Controls. Highlighted when it
    -- is the Part Part Controls is on, so the two tabs visibly agree.
    if ImGui.Selectable(ctx, ('%d##part-row-%d'):format(part, part),
                        part == current) and track then
      override = part
      set_status('')
      jump_to_part = true
    end

    ImGui.TableNextColumn(ctx)
    voice_button(track, part, -1)

    for _, col in ipairs(GRID_COLUMNS) do
      ImGui.TableNextColumn(ctx)
      local prm = P.BY_ID[col.id]
      -- -1: fill the column, whatever the user resized it to.
      if grid_cell(prm, part, -1) then
        commit(track, part, prm.id, channels[part].values[prm.id])
      end
    end
  end

  end_table()
end

-- The sidebar: one selectable per page, down the left edge.
-- The sidebar: one selectable per page, down the left edge.
--
-- Borders make the divider visible, which is what the demo's two-pane layout
-- does and what stops the page list reading as loose text over the rows.
local function sidebar(w)
  if begin_child('sidebar', w, 0, ImGui.ChildFlags_Borders) then
    for i, entry in ipairs(PAGES) do
      if ImGui.Selectable(ctx, entry.name, i == page) then page = i end
    end
    end_child()
  end
end

-- Draw the Overview, the Part controls and the Drum controls.
--
-- The tabs edit three different things: every Part at once, one Part, and
-- one shared drum MAP -- every note of it, or one. Only the last is not keyed by Part at all -- two
-- Parts on DRUM 1 show one set of values, because that is what the hardware
-- holds.
--
-- The sidebar and the rows are separate children so the selectables cannot
-- widen with a long parameter name, and so the rows scroll without taking the
-- sidebar with them.
local function panel(track, part, em)
  if begin_tab_bar('control-tabs') then
    -- Overview first, as the XG panel has it: the whole instrument before
    -- any one Part of it.
    local on_overview = begin_tab_item(OVERVIEW_TAB)
    -- Recorded for the NEXT frame's header, which draws before the tab bar
    -- and so cannot ask which tab is open. A tab change therefore reaches
    -- the picker one frame late -- invisible at frame rate, and the
    -- alternative is drawing the header after the body it sits above.
    showing_overview = on_overview
    if on_overview then
      if not track then begin_disabled() end
      overview(track, part, em)
      if not track then end_disabled() end
      end_tab_item()
    end

    local jump = jump_to_part and ImGui.TabItemFlags_SetSelected or nil
    jump_to_part = false
    if begin_tab_item('Part Controls', jump) then
      -- The tab navigation remains usable without a route; only the controls
      -- that need somewhere to send become inert. A track is enough -- these
      -- sliders only ever reach the hardware.
      if not track then begin_disabled() end

      -- Two panes side by side. The sidebar takes a fixed width and the
      -- rows take what is left; both ask for the full remaining HEIGHT,
      -- which is what keeps the divider running the length of the page.
      sidebar(em * 8)
      ImGui.SameLine(ctx)

      if begin_child('rows', 0, 0) then
        if PAGES[page].matrix then
          draw_matrix(track, part, em)
        else
          draw_page(PAGES[page], track, part, em * 12)
        end
        end_child()
      end

      if not track then end_disabled() end
      end_tab_item()
    end

    -- Both drum tabs edit the selected Part's MAP. A normal tone Part has
    -- none, so the complete panel is drawn from DRUM 1's values and greyed
    -- out -- visible and inert, rather than an empty tab that says nothing
    -- about why there is nothing to edit. A missing route disables it for the
    -- same reason Part Controls is disabled without one.
    local mode = drum_display_mode(part)
    local editable = track ~= nil and drum_mode_of(part) ~= nil

    local on_drum_overview = begin_tab_item(DRUM_OVERVIEW_TAB)
    if on_drum_overview then
      if not editable then begin_disabled() end
      drum_overview(track, mode, editable, em)
      if not editable then end_disabled() end
      end_tab_item()
    end

    local on_drum = begin_tab_item(DRUM_TAB,
      jump_to_drum and ImGui.TabItemFlags_SetSelected or nil)
    jump_to_drum = false
    -- Recorded for the NEXT frame's footer, which draws outside the tab bar,
    -- the same one-frame-late way showing_overview is.
    showing_drum = on_drum or on_drum_overview
    if on_drum then
      if not editable then begin_disabled() end
      if begin_child('drum-rows', 0, 0) then
        draw_drum_page(track, mode, editable, em * 12)
        end_child()
      end
      if not editable then end_disabled() end
      end_tab_item()
    end
    end_tab_bar()
  end
end

-- footer -------------------------------------------------------------------------

-- Set by the footer button; read by the loop, which owns the one exit. A flag
-- rather than a direct call because closing has to happen between frames, not
-- in the middle of one still drawing into the context.
local want_close = false
local function request_close() want_close = true end

local function footer(take, track, part)
  ImGui.Separator(ctx)

  if ImGui.Button(ctx, 'Back to PAGER') then request_close() end

  ImGui.SameLine(ctx)

  -- What Insert would write.
  --
  -- On the Overview every Part is editable at once, so the pending edits are
  -- whatever any channel holds -- an edit made on row 9 belongs to Part 9
  -- whatever the header says. Elsewhere only the Part on screen counts, so
  -- Insert cannot quietly write a channel the user is not looking at.
  -- On either drum tab Insert writes every pending note of the SELECTED
  -- PART'S MAP, and nothing else. A normal tone Part has no drum map, so it has no drum
  -- insertion target at all and Insert stays disabled -- the panel is drawn
  -- greyed out in that case and there is nothing pending behind it.
  --
  -- Switching tabs only changes what Insert is pointed at. Every pending
  -- edit, Part and drum alike, survives the move.
  local drum_target = showing_drum and part and drum_mode_of(part) or nil
  if drum_target and #drum_pending_list(drum_target) == 0 then
    drum_target = nil
  end

  local targets
  if showing_drum then
    -- Part pending edits are not Insert's business while this tab is up.
    targets = {}
  elseif showing_overview then
    targets = pending_parts()
  elseif part and channels[part] and channels[part].pending then
    targets = { part }
  else
    targets = {}
  end

  local can_insert = take ~= nil and (#targets > 0 or drum_target ~= nil)
  if not can_insert then begin_disabled() end
  if ImGui.Button(ctx, 'Insert') and can_insert then
    -- One undo point per Part, as everywhere else: each Insert is its own
    -- edit and each reports its own failure.
    for _, target in ipairs(targets) do insert_pending(take, target) end
    if drum_target then insert_drum_pending(take, drum_target) end
  end
  if not can_insert then end_disabled() end

  ImGui.SameLine(ctx)
  if showing_drum then
    local mode = part and drum_mode_of(part)
    if mode then ImGui.Text(ctx, drum_pending_text(mode)) end
  elseif showing_overview then
    if #targets == 1 then
      -- pending_text already starts with "Pending:", so the Part is named
      -- after it rather than in front.
      ImGui.Text(ctx, ('%s (Part %d)'):format(pending_text(targets[1]),
                                              targets[1]))
    elseif #targets > 1 then
      ImGui.Text(ctx, ('Pending: %d Parts'):format(#targets))
    end
  elseif part then
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

  -- Inert on the Drum Controls tab: every drum control is a DT1 write, with
  -- no CC or RPN form to fall back to, so the checkbox governs nothing there.
  -- Greyed rather than hidden, and the SAVED VALUE IS LEFT ALONE -- it still
  -- describes how this channel's Part controls encode, and the user returns
  -- to that tab with the setting they left.
  local live = part ~= nil and track ~= nil and not showing_drum
  if not live then begin_disabled() end
  local changed, on = ImGui.Checkbox(ctx, label, channels[part or 1].use_sysex)
  if changed and live then channels[part].use_sysex = on end
  if not live then end_disabled() end

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
    -- The voice goes with the values: a reopened editor must show the Part
    -- the user left it on, not the power-on default it has long since moved
    -- away from. Copied field by field so nothing but plain data crosses.
    local v = ch.voice
    out[tostring(i)] = {
      values = values, use_sysex = ch.use_sysex,
      voice = { msb = v.msb, lsb = v.lsb, pc = v.pc },
    }
  end
  -- The drum kits are shared between Parts, so they are saved once rather
  -- than sixteen times. Keyed by mode, as they are held.
  local kits = {}
  for mode = 1, 2 do
    local k = drum_kits[mode]
    kits[tostring(mode)] = { msb = k.msb, lsb = k.lsb, pc = k.pc }
  end

  -- The shared drum control maps, saved once each rather than per Part --
  -- they belong to the map, and sixteen copies would be sixteen chances to
  -- disagree.
  --
  -- Only the notes that EXIST are stored. The table is sparse by design: 128
  -- notes across nine parameters on two maps is 2304 values, nearly all of
  -- them untouched, and a record that wrote them all would bury what the user
  -- actually edited. Values are copied field by field so nothing but plain
  -- data crosses, and the pending edit is deliberately absent -- transient by
  -- contract, exactly like a channel's.
  local maps = {}
  for mode = 1, 2 do
    local map = drum_maps[mode]
    local notes = {}
    for note, values in pairs(map.notes) do
      local copy = {}
      for _, p in ipairs(D.PARAMS) do copy[p.id] = values[p.id] end
      notes[tostring(note)] = copy
    end
    maps[tostring(mode)] = { selected_note = map.selected_note, notes = notes }
  end

  return { channels = out, drum_kits = kits, drum_maps = maps }
end

-- Apply a saved state. Passive by contract: this writes values into the
-- tables the UI draws from and queues nothing, so nothing reaches the
-- hardware until the user's next edit.
--
-- Every restored value goes through P.validate, which DROPS anything outside
-- the parameter's documented range rather than clamping it. A clamped value
-- looks deliberate on screen and the user cannot see which field came back
-- wrong. Unknown fields are ignored, for forward compatibility.
-- A saved voice address, or nil when it is not three valid MIDI bytes.
-- A partial address would name a different voice than the one saved, which
-- is worse than falling back to the default.
local function valid_voice(sv)
  if type(sv) ~= 'table' then return nil end
  for _, n in ipairs({ sv.msb, sv.lsb, sv.pc }) do
    if type(n) ~= 'number' or n < 0 or n > 127 or n ~= math.floor(n) then
      return nil
    end
  end
  return sv
end

local function restore_state(st)
  if type(st) ~= 'table' or type(st.channels) ~= 'table' then return false end

  -- The shared drum kits, saved once rather than per channel.
  if type(st.drum_kits) == 'table' then
    for mode = 1, 2 do
      local sv = valid_voice(st.drum_kits[tostring(mode)])
      if sv then
        drum_kits[mode].msb, drum_kits[mode].lsb, drum_kits[mode].pc =
          sv.msb, sv.lsb, sv.pc
      end
    end
  end

  -- The shared drum control maps. Defensive throughout, and PASSIVE: this
  -- writes into the tables the UI draws from and queues nothing, creates no
  -- pending edit and inserts nothing.
  --
  -- A record from before this feature simply has no drum_maps field, which is
  -- not an error -- the maps keep their seeds and the session still restores.
  if type(st.drum_maps) == 'table' then
    for mode = 1, 2 do
      local saved = st.drum_maps[tostring(mode)]
      if type(saved) == 'table' then
        local map = drum_maps[mode]

        if D.valid_note(saved.selected_note) then
          map.selected_note = saved.selected_note
        end

        if type(saved.notes) == 'table' then
          for key, values in pairs(saved.notes) do
            -- Keys arrive as strings from JSON. Anything that is not an
            -- integer 0..127 names no note at all and is ignored rather than
            -- creating an entry under a key nothing can reach.
            local note = tonumber(key)
            if D.valid_note(note) and type(values) == 'table' then
              local target = drum_note(mode, note)
              for _, p in ipairs(D.PARAMS) do
                -- Validated per parameter, and DROPPED rather than clamped
                -- when invalid: the note keeps its deterministic seed for
                -- that field, so a value that came back wrong is visible
                -- instead of looking like a deliberate setting.
                local v = D.validate(p, values[p.id])
                if v ~= nil then target[p.id] = v end
              end
            end
          end
        end
      end
    end
  end

  for i = 1, 16 do
    local saved = st.channels[tostring(i)]
    if type(saved) == 'table' then
      local ch = channels[i]
      if type(saved.use_sysex) == 'boolean' then ch.use_sysex = saved.use_sysex end

      local sv = valid_voice(saved.voice)
      if sv then
        ch.voice.msb, ch.voice.lsb, ch.voice.pc = sv.msb, sv.lsb, sv.pc
      end
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
  -- The override belongs to the project it was picked in; the new tab has its
  -- own piano roll to follow.
  override, rolled = nil, nil
  reset_drum_kits()
  -- The shared drum maps belong to the project too, pending edits included:
  -- recreated before the new project's state is restored over them, so
  -- nothing leaks from one tab into another.
  reset_drum_maps()
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
  local track = active_track(take)
  local part = visible_part(ed)
  local em = ImGui.GetFontSize(ctx)

  -- Header: the Part being edited, chosen here rather than only in the piano
  -- roll. The encoding switch lives in the footer beside Insert, because that
  -- is the action it governs.
  -- Notice first, picker right-aligned after it: the picker is the control
  -- the user reaches for, and the right edge is where the XG panel puts its
  -- Part selector.
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, context_notice(take, track))

  local picker_w = em * 10
  ImGui.SameLine(ctx)
  local avail = ImGui.GetContentRegionAvail(ctx)
  local x, y = ImGui.GetCursorPos(ctx)
  ImGui.SetCursorPos(ctx, x + math.max(0, avail - picker_w), y)
  channel_picker(part, track, em)

  -- An error is reported in the header, not only in the footer: a throw
  -- inside the body child skips everything after it, the footer included, so
  -- a status line that lives only down there is invisible in exactly the
  -- case it is needed.
  if status:find('^ERROR') then
    ImGui.Text(ctx, status)
  end

  ImGui.Separator(ctx)

  local footer_h = ImGui.GetFrameHeightWithSpacing(ctx) * 2
                 + select(2, ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing))

  -- Everything is drawn either way; without an editor the Part controls are
  -- inert, while the tab navigation remains available.
  if begin_child('body', 0, -footer_h) then
    panel(track, part, em)
    end_child()
  end

  footer(take, track, part)
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
    --
    -- A child left open is the same trap one level down: End() then raises
    -- "Must call EndChild() and not End()", which names this line rather than
    -- whatever actually threw. Unwinding first is what keeps the real error
    -- the one that gets reported.
    -- xpcall with a traceback: the bare message names the line that threw
    -- but not the path that reached it, and this frame nests several layers
    -- deep behind a tab and a sidebar page.
    local ok, err = xpcall(frame, debug.traceback)
    if not ok then unwind_scopes() end
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

  -- Pending snapshots do not survive a close, by design. Neither does the
  -- channel override: a new visit opens on the piano roll's channel again.
  reset_channels()
  reset_drum_kits()
  reset_drum_maps()
  override, rolled = nil, nil

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
