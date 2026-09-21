-- Phase 5: the Part Editor panel, its channel binding and its one-pending
-- snapshot rule.
--
-- Two halves, because they catch different things.
--
-- The first lifts the pure functions out of part_editor.lua and runs them
-- against a small environment. That is where the invariants live: one pending
-- snapshot per channel, replacement by the next touch, clearing on success,
-- retention on failure, and what a restore keeps or drops.
--
-- The second drives the whole tool through a headless ImGui, the same way
-- test_tool_lifecycle.lua drives the Effects Editor, to prove the window
-- opens, draws with balanced stacks, closes once and restores passively.
--   lua tests/test_part_editor.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path
local EDITOR = dir .. '/../editor/'

local H = require 'harness'
local P = require 'part_params'
local D = require 'drum_params'
local check = H.check

local FILE = 'part_editor.lua'

-- lifted logic ----------------------------------------------------------------

-- The environment the lifted functions see. Anything they reach for that is
-- absent raises here rather than passing quietly, which is the point: a new
-- dependency on editor state shows up as a failure the moment it appears.
-- The two shared drum control maps, as reset_drum_maps() builds them: one
-- per Part Mode, each with its own selected note, its own sparse note table
-- and its own pending edits, one per note. Held outside the channel tables because a drum
-- value belongs to the MAP -- every Part playing it sees the same values.
local function fresh_drum_maps()
  return {
    { selected_note = 0, notes = {}, pending = {} },
    { selected_note = 0, notes = {}, pending = {} },
  }
end

local function env(over)
  local e = {
    P = P,
    D = D,
    PM = require 'part_messages',
    DM = require 'drum_messages',
    ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
    tonumber = tonumber,
    math = math, string = string, table = table, pcall = pcall,
    channels = {},
    -- The two shared drum kits, one per Part Mode. Held outside the channel
    -- tables because the kit belongs to the mode, not to the Part.
    -- lsb 4 is the SC-8850 map, which is what blank_channel's voices use.
    -- The LSB matters now: a kit is (map, program change), so the factory
    -- seed is read against it.
    drum_kits = {
      { msb = 0, lsb = 4, pc = 0 },
      { msb = 0, lsb = 4, pc = 0 },
    },
    drum_maps = fresh_drum_maps(),
    status = '', status_time = 0,
  }
  for k, v in pairs(over or {}) do e[k] = v end
  return e
end

local function blank_values()
  local v = {}
  for _, p in ipairs(P.PARAMS) do v[p.id] = p.default end
  return v
end

-- Mirrors blank_channel() in the editor, including the voice each Part
-- holds: capture_state reads it, so a fixture without one is not a channel.
local function fresh_channels()
  local c = {}
  for i = 1, 16 do
    local values = blank_values()
    -- Part 10 is the drum Part at power-on, as blank_channel() sets it.
    if i == 10 then values.rhythm = 1 end
    c[i] = { values = values, use_sysex = false, pending = nil,
             voice = { msb = 0, lsb = 4, pc = 0, drum = i == 10 } }
  end
  return c
end

-- display rules ------------------------------------------------------------------

do
  local e = env()
  local display_value = H.lift({ 'display_value' }, e, FILE)

  local CASES = {
    { 'level', 100, '100' },
    { 'cutoff', 20, '+20' },        -- relative modifiers read as offsets
    { 'cutoff', -20, '-20' },
    { 'cutoff', 0, '+0' },
    { 'pan', 0, 'C' },
    { 'pan', -63, 'L63' },
    { 'pan', 41, 'R41' },
    { 'pitch_key', 7, '+7 st' },
    { 'bend_range', 2, '+2 st' },
    { 'tuning_offset', -3.4, '-3.4 Hz' },
    { 'tuning_offset', 0, '+0.0 Hz' },
    { 'fine_tune', 50, '+50 cents' },
    { 'eq', 1, 'On' },
    { 'eq', 0, 'Off' },
    { 'porta', 0, 'Off' },
    { 'key_low', 0, 'C-1' },          -- the manual's own note names
    { 'key_low', 60, 'C4' },
    { 'key_high', 127, 'G9' },
    { 'rx_channel', 17, 'Off' },
    { 'rx_channel', 10, '10' },
    { 'scale_c', -12, '-12 cents' },
  }
  for _, c in ipairs(CASES) do
    local got = display_value(P.BY_ID[c[1]], c[2])
    check(got == c[3],
      ('display %s %s = %s, expected %s'):format(c[1], c[2], got, c[3]))
  end
  H.pass('values display in musical units, not bytes (21 cases)')
end

-- the pending snapshot ---------------------------------------------------------------

do
  local e = env({ channels = fresh_channels() })
  -- pending_text calls display_value, so the three are lifted together into
  -- one chunk: lifted functions see each other as upvalues only when they
  -- are compiled side by side.
  local _, sp, pt = H.lift(
    { 'display_value', 'set_pending', 'pending_text' }, e, FILE)

  -- Nothing pending to start with, on every channel.
  for i = 1, 16 do
    check(pt(i) == '', 'channel ' .. i .. ' must start with nothing pending')
  end

  -- One touch, one snapshot, and the footer names it.
  sp(1, 'cutoff', 20)
  check(e.channels[1].pending.id == 'cutoff', 'the touch must become pending')
  check(pt(1) == 'Pending: Cutoff +20',
    'the footer must name the parameter and value, got ' .. pt(1))

  -- The next touch REPLACES it. Pending parameters never accumulate -- that
  -- is what keeps Insert unambiguous.
  sp(1, 'level', 90)
  check(e.channels[1].pending.id == 'level', 'the newest touch must win')
  check(pt(1) == 'Pending: Level 90', 'the footer must follow, got ' .. pt(1))

  -- Touching the same parameter again updates the value, still one snapshot.
  sp(1, 'level', 20)
  check(e.channels[1].pending.value == 20, 'the newest value must win')

  -- Channels are independent: each keeps at most one, and switching away and
  -- back reveals the same one.
  sp(2, 'pan', -30)
  check(e.channels[1].pending.id == 'level', 'channel 1 keeps its own snapshot')
  check(e.channels[2].pending.id == 'pan', 'channel 2 keeps its own snapshot')
  check(pt(2) == 'Pending: Pan L30', 'channel 2 footer, got ' .. pt(2))
  for i = 3, 16 do
    check(e.channels[i].pending == nil, 'channel ' .. i .. ' must stay empty')
  end
  H.pass('one pending snapshot per channel, replaced by the next touch (24 cases)')
end

-- insert: clearing and retention ---------------------------------------------------------

do
  -- A stub inserter, so this tests the editor's decision rather than
  -- part_insert.lua, which phase 4 already covers.
  local calls = {}
  local result = { true, nil }
  local e = env({
    channels = fresh_channels(),
    inserter = {
      insert = function(_, take, id, value, part, use_sysex)
        calls[#calls + 1] = { take = take, id = id, value = value,
                              part = part, use_sysex = use_sysex }
        return result[1], result[2]
      end,
    },
  })
  e.reaper = { time_precise = function() return 0 end }
  local _, _, insert_pending = H.lift(
    { 'display_value', 'set_status', 'insert_pending' }, e, FILE)

  -- Nothing pending: Insert reports and writes nothing.
  insert_pending('TAKE', 1)
  check(#calls == 0, 'Insert with nothing pending must not reach the take')
  check(e.status ~= '', 'and must say so')

  -- A successful Insert clears the snapshot.
  e.channels[1].pending = { id = 'cutoff', value = 20 }
  insert_pending('TAKE', 1)
  check(#calls == 1, 'Insert must reach the inserter')
  check(calls[1].id == 'cutoff' and calls[1].value == 20 and calls[1].part == 1,
    'it must pass the pending parameter, value and part')
  check(e.channels[1].pending == nil, 'a successful Insert must clear the snapshot')
  check(e.status:find('Inserted', 1, true), 'and must confirm, got ' .. e.status)

  -- A failed Insert KEEPS it, so the user can correct the context and retry.
  result = { false, 'no take' }
  e.channels[1].pending = { id = 'level', value = 90 }
  insert_pending('TAKE', 1)
  check(e.channels[1].pending ~= nil, 'a failed Insert must retain the snapshot')
  check(e.channels[1].pending.id == 'level', 'and must not alter it')
  check(e.status:find('failed', 1, true), 'and must report, got ' .. e.status)

  -- The encoding is chosen at INSERT time, from the channel's current
  -- setting -- not from whatever was active when the value was touched.
  result = { true, nil }
  e.channels[3].use_sysex = true
  e.channels[3].pending = { id = 'cutoff', value = 20 }
  insert_pending('TAKE', 3)
  check(calls[#calls].use_sysex == true,
    'Insert must use the channel\'s Use SysEx? setting at insertion time')
  check(calls[#calls].part == 3, 'and the channel it was pressed on')
  H.pass('Insert clears on success, retains on failure, encodes at press time (13 cases)')
end

-- preview: a route failure keeps the edit --------------------------------------------------

do
  local queued, route_ok = {}, true
  local e = env({
    channels = fresh_channels(),
    hw = {
      preview_events = function(_, events, take, addr)
        if not route_ok then return false, 'No MIDI hardware output on this track.' end
        queued[#queued + 1] = { n = #events, take = take, addr = addr }
        return true
      end,
    },
    reaper = { time_precise = function() return 0 end },
  })
  -- commit calls preview and set_pending, so all four compile together.
  local _, _, _, _, cm = H.lift(
    { 'set_status', 'part_key', 'preview', 'set_pending', 'commit' }, e, FILE)

  -- A settled edit previews and becomes pending, in that order of effect:
  -- both must be true afterwards.
  cm('TAKE', 1, 'cutoff', 20)
  check(#queued == 1, 'a settled edit must preview')
  -- The preview key names the PART as well as the parameter. The queue pairs
  -- it with the resolved device and treats that pair as the identity of a
  -- pending edit, so a bare 'cutoff' would let an edit on one Part discard
  -- another Part's unsent edit to the same control.
  check(queued[1].addr == 'part:1:cutoff',
    'the preview key must name the Part and the parameter, got '
    .. tostring(queued[1].addr))
  check(e.channels[1].pending.id == 'cutoff', 'and must become pending')

  -- Two Parts are two keys, which is what keeps them from coalescing.
  cm('TAKE', 2, 'cutoff', 30)
  check(queued[#queued].addr == 'part:2:cutoff',
    'another Part must produce another key, got ' .. tostring(queued[#queued].addr))

  -- A route failure reports but does NOT discard the edit: the value stays
  -- pending and insertable, which is the design's explicit rule.
  route_ok = false
  cm('TAKE', 1, 'level', 90)
  check(e.channels[1].pending.id == 'level',
    'a hardware failure must not discard the manual edit')
  check(e.status ~= '' and e.status:find('insertable', 1, true),
    'and must say the value is still insertable, got ' .. e.status)

  -- An RPN previews as its whole ordered run, in one call.
  route_ok = true
  cm('TAKE', 1, 'bend_range', 12)
  check(queued[#queued].n == 5, 'an RPN must preview as its whole run, got '
    .. queued[#queued].n)

  -- The channel's Use SysEx? setting selects the encoding.
  e.channels[1].use_sysex = true
  cm('TAKE', 1, 'bend_range', 12)
  check(queued[#queued].n == 1, 'the SysEx form is a single message, got '
    .. queued[#queued].n)
  H.pass('a settled edit previews and stays pending even when the route fails (10 cases)')
end

-- the active Part comes from the MIDI editor ------------------------------------------------

do
  local setting
  local e = env({
    reaper = {
      MIDIEditor_GetSetting_int = function(_, name)
        check(name == 'default_note_chan',
          'the Part must come from default_note_chan, not ' .. tostring(name))
        return setting
      end,
    },
  })
  local active_part = H.lift({ 'active_part' }, e, FILE)

  -- default_note_chan is zero-based; the panel shows Channel 1..16.
  local CASES = { { 0, 1 }, { 9, 10 }, { 15, 16 } }
  for _, c in ipairs(CASES) do
    setting = c[1]
    check(active_part('ED') == c[2],
      ('default_note_chan %d must be Part %d, got %s')
        :format(c[1], c[2], tostring(active_part('ED'))))
  end

  -- Nonsense falls back to Part 1 rather than indexing the channel table
  -- with nil, which would take the window down mid-frame.
  for _, bad in ipairs({ -1, 16, 99, 'x' }) do
    setting = bad
    check(active_part('ED') == 1,
      'an out-of-range channel must fall back to Part 1, got ' ..
      tostring(active_part('ED')))
  end

  -- No editor at all is the disabled state, and is distinct from Part 1.
  check(active_part(nil) == nil, 'no editor means no Part')
  H.pass('the Part is the piano roll\'s channel, with a safe fallback (9 cases)')
end

-- session state ---------------------------------------------------------------------------

do
  local e = env({ channels = fresh_channels() })
  -- valid_voice is lifted too: restore_state calls it, and lifted functions
  -- only see each other when compiled side by side.
  local _, capture_state, restore_state = H.lift(
    { 'valid_voice', 'capture_state', 'restore_state' }, e, FILE)

  -- What is saved: per-channel values and per-channel Use SysEx?.
  e.channels[1].values.cutoff = 20
  e.channels[1].use_sysex = true
  e.channels[16].values.level = 12
  local st = capture_state()
  check(st.channels['1'].values.cutoff == 20, 'values are captured per channel')
  check(st.channels['1'].use_sysex == true, 'Use SysEx? is captured per channel')
  check(st.channels['16'].values.level == 12, 'channel 16 is captured')
  check(st.channels['2'].use_sysex == false, 'an untouched channel keeps its default')

  -- What is NOT saved: pending snapshots are transient by contract.
  e.channels[1].pending = { id = 'cutoff', value = 20 }
  local st2 = capture_state()
  local json = require 'json'
  check(not json.encode(st2):find('pending', 1, true),
    'a pending snapshot must never be written to session state')

  -- A restore is passive and per channel.
  e.channels = fresh_channels()
  check(restore_state(st) == true, 'a well-formed record must restore')
  check(e.channels[1].values.cutoff == 20, 'values come back')
  check(e.channels[1].use_sysex == true, 'Use SysEx? comes back')
  check(e.channels[16].values.level == 12, 'channel 16 comes back')
  check(e.channels[1].pending == nil, 'a restore must not create a pending edit')

  -- Invalid values are DROPPED, not clamped: a clamped value looks deliberate
  -- on screen and the user cannot see which field came back wrong.
  e.channels = fresh_channels()
  restore_state({ channels = { ['1'] = { values = {
    cutoff = 999,          -- above its range
    level = -5,            -- below its range
    pan = 'x',             -- not a number
    resonance = 20,        -- valid, and must survive alongside the rest
    nonesuch = 7,          -- an unknown field, ignored for forward compat
  } } } })
  check(e.channels[1].values.cutoff == P.BY_ID.cutoff.default,
    'an out-of-range value must be dropped, not clamped')
  check(e.channels[1].values.level == P.BY_ID.level.default, 'and below-range too')
  check(e.channels[1].values.pan == P.BY_ID.pan.default, 'and a non-number')
  check(e.channels[1].values.resonance == 20, 'a valid sibling must still restore')

  -- Malformed records restore nothing rather than raising.
  check(restore_state(nil) == false, 'nil is not a record')
  check(restore_state({}) == false, 'a record without channels is not one')
  check(restore_state({ channels = 'x' }) == false, 'channels must be a table')
  check(restore_state({ channels = { ['1'] = 'x' } }) == true,
    'a malformed channel is skipped, not fatal')
  H.pass('session state saves values and Use SysEx?, never pending (18 cases)')
end

-- shared drum map state ------------------------------------------------------------

-- The invariant this whole feature turns on: a drum value belongs to the MAP,
-- not to a Part. Two Parts set to DRUM 1 see one set of values and one
-- pending edit; DRUM 1 and DRUM 2 see neither of each other's.
--
-- Lifted rather than driven through ImGui, because what is being tested is
-- the ownership model rather than the widgets that display it.

do
  local e = env({ channels = fresh_channels() })
  local _, drum_note, drum_mode_of, drum_display_mode = H.lift(
    { 'drum_kit_of', 'drum_note', 'drum_mode_of', 'drum_display_mode' }, e, FILE)

  -- An unseen note is created from the seed on first sight, and the same
  -- table comes back every time after that -- that sameness IS the sharing.
  local first = drum_note(1, 60)
  check(type(first) == 'table', 'a note must resolve to a value table')
  -- Seeded from the kit the map is on. The fixture's kits are program
  -- change 0, STANDARD 1, whose note 60 is Hi Bongo -- a genuinely custom
  -- instrument rather than a flat default, which is the whole reason the
  -- factory table is shipped. Compared against drum_params rather than
  -- restated here, so this follows the data instead of duplicating it.
  local want = D.seed_values(60, 0, 4)
  for _, p in ipairs(D.PARAMS) do
    check(first[p.id] == want[p.id],
      ('a fresh note must seed from its kit: %s is %s, expected %s')
        :format(p.id, tostring(first[p.id]), tostring(want[p.id])))
  end
  check(want.reverb ~= 0, 'and that kit\'s note 60 really does carry reverb')
  check(drum_note(1, 60) == first,
    'the same note must return the SAME table, not a copy')

  -- Sparse: only what has been looked at exists.
  check(e.drum_maps[1].notes[60] == first, 'the note is stored on its map')
  check(e.drum_maps[1].notes[61] == nil, 'an untouched note must not exist yet')

  -- A write through one reference is visible through every other, which is
  -- what makes two Parts on one map agree.
  first.level = 40
  check(drum_note(1, 60).level == 40, 'a write must be visible to every reader')

  -- The two maps are independent storage.
  check(drum_note(2, 60) ~= first, 'DRUM 2 note 60 is not DRUM 1 note 60')
  check(drum_note(2, 60).level == want.level,
    'and keeps its own seed, unaffected by the edit on DRUM 1')
  check(drum_note(1, 60).level == 40, 'while DRUM 1 keeps its edit')

  -- So are two notes on one map.
  check(drum_note(1, 61) ~= first, 'two notes are two tables')

  -- Invalid coordinates resolve to nothing rather than creating a phantom
  -- entry under a key nothing can reach again.
  for _, bad in ipairs({ { 0, 60 }, { 3, 60 }, { 1, -1 }, { 1, 128 },
                         { 1, 60.5 }, { 1, 'x' } }) do
    check(drum_note(bad[1], bad[2]) == nil,
      ('map %s note %s must resolve to nothing')
        :format(tostring(bad[1]), tostring(bad[2])))
  end
  check(e.drum_maps[1].notes[-1] == nil, 'and must store nothing')

  -- Which map a Part's controls belong to. Part 10 is DRUM 1 at power-on;
  -- every other Part is a normal tone Part with no map at all.
  check(drum_mode_of(10) == 1, 'Part 10 is on DRUM 1 at power-on')
  check(drum_mode_of(1) == nil, 'a normal Part has no drum map')
  e.channels[11].values.rhythm = 2
  check(drum_mode_of(11) == 2, 'a DRUM 2 Part is on map 2')

  -- Any number of Parts may share a map: the limit is two MAPS, not two
  -- drum Parts.
  e.channels[12].values.rhythm = 1
  check(drum_mode_of(12) == 1 and drum_mode_of(10) == 1,
    'two Parts may both be on DRUM 1')
  check(drum_note(1, 60) == first,
    'and both address the same shared values')

  -- A normal Part still has a map to DISPLAY -- DRUM 1, inert -- so the
  -- panel can draw greyed out rather than empty.
  check(drum_display_mode(1) == 1, 'a normal Part displays DRUM 1')
  check(drum_display_mode(11) == 2, 'a DRUM 2 Part displays its own map')
  H.pass('drum values are shared per map, not per Part (24 cases)')
end

-- the map's pending edits ------------------------------------------------------------

do
  local e = env({ channels = fresh_channels() })
  local _, _, set_drum_pending, drum_pending_text = H.lift(
    { 'drum_display', 'drum_pending_list', 'set_drum_pending',
      'drum_pending_text' }, e, FILE)

  check(drum_pending_text(1) == '' and drum_pending_text(2) == '',
    'both maps start with nothing pending')

  -- One touch, one snapshot, and the footer names map, note, control, value.
  set_drum_pending(1, 60, 'level', 100)
  local pend = e.drum_maps[1].pending[60]
  check(pend and pend.id == 'level', 'the touch must become pending')
  check(pend.note == 60, 'carrying its note')
  check(pend.mode == 1, 'and its map')
  check(drum_pending_text(1) == 'Pending: Drum 1 Note 60 Level 100',
    'the footer must name all four, got ' .. drum_pending_text(1))

  -- A second control on the SAME note replaces it: one pending edit per
  -- note, exactly as one per channel on the Part side.
  set_drum_pending(1, 60, 'pan', -10)
  check(e.drum_maps[1].pending[60].id == 'pan', 'the newest control must win')
  check(drum_pending_text(1) == 'Pending: Drum 1 Note 60 Pan -10',
    'and Pan reads as its canonical number, got ' .. drum_pending_text(1))

  -- A second NOTE keeps its own, which is what the Drum Overview edits.
  set_drum_pending(1, 61, 'level', 20)
  check(e.drum_maps[1].pending[60].id == 'pan', 'note 60 keeps its edit')
  check(e.drum_maps[1].pending[61].id == 'level', 'and note 61 holds its own')
  check(drum_pending_text(1) == 'Pending: Drum 1, 2 notes',
    'several notes are counted, got ' .. drum_pending_text(1))

  -- The OTHER map keeps its own. The user may switch between a DRUM 1 Part
  -- and a DRUM 2 Part with edits outstanding on each.
  set_drum_pending(2, 38, 'reverb', 64)
  check(e.drum_maps[1].pending[61] ~= nil, 'DRUM 1 keeps its pending edits')
  check(e.drum_maps[2].pending[38].id == 'reverb', 'and DRUM 2 keeps its own')
  check(drum_pending_text(2) == 'Pending: Drum 2 Note 38 Reverb 64',
    'each map names itself, got ' .. drum_pending_text(2))

  -- A switch reads as On/Off rather than as 1/0.
  e.drum_maps[1].pending = {}
  set_drum_pending(1, 42, 'rx_note_on', 0)
  check(drum_pending_text(1) == 'Pending: Drum 1 Note 42 Rx Note On Off',
    'a switch reads as a state, got ' .. drum_pending_text(1))
  H.pass('one pending drum edit per note, replaced by the next touch (16 cases)')
end

-- drum preview: a route failure keeps the edit -----------------------------------------

do
  local queued, route_ok = {}, true
  local e = env({
    channels = fresh_channels(),
    hw = {
      preview_events = function(_, events, route, addr)
        if not route_ok then return false, 'No MIDI hardware output on this track.' end
        queued[#queued + 1] = { n = #events, addr = addr,
                                payload = events[1] and events[1].payload }
        return true
      end,
    },
    HardwareOutput = { NO_TRACK = 'No track.' },
    reaper = { time_precise = function() return 0 end },
  })
  local _, _, _, _, _, drum_commit = H.lift(
    { 'set_status', 'drum_display', 'drum_pending_list', 'set_drum_pending',
      'drum_preview', 'drum_commit' }, e, FILE)

  -- A settled edit previews and becomes pending; both must be true after.
  drum_commit('TRK', 1, 60, 'level', 100)
  check(#queued == 1, 'a settled drum edit must preview')
  check(queued[1].n == 1, 'as exactly one message, got ' .. queued[1].n)
  check(e.drum_maps[1].pending[60].id == 'level', 'and must become pending')

  -- The key names map, note and parameter -- never a Part, which is not part
  -- of a drum value's identity. The queue pairs it with the resolved device.
  check(queued[1].addr == 'drum:1:60:level',
    'the preview key must be map, note and parameter, got ' ..
    tostring(queued[1].addr))

  -- Each coordinate produces its own key, which is what stops two notes or
  -- two maps discarding one another in the queue.
  drum_commit('TRK', 2, 60, 'level', 100)
  check(queued[#queued].addr == 'drum:2:60:level', 'another map, another key')
  drum_commit('TRK', 1, 61, 'level', 100)
  check(queued[#queued].addr == 'drum:1:61:level', 'another note, another key')
  drum_commit('TRK', 1, 60, 'pan', 10)
  check(queued[#queued].addr == 'drum:1:60:pan', 'another control, another key')

  -- A route failure reports but does NOT discard the edit: pending first,
  -- preview second, so the value stays insertable.
  route_ok = false
  local before = #queued
  drum_commit('TRK', 1, 60, 'reverb', 50)
  check(#queued == before, 'a failed route queues nothing')
  check(e.drum_maps[1].pending[60].id == 'reverb',
    'but the edit must still be pending')
  check(e.status:find('insertable', 1, true),
    'and must say it is still insertable, got ' .. e.status)

  -- No track at all is the same rule, reported differently.
  route_ok = true
  drum_commit(nil, 1, 60, 'chorus', 30)
  check(e.drum_maps[1].pending[60].id == 'chorus',
    'a missing track must not discard the edit either')
  check(e.status:find('insertable', 1, true), 'and must say so')

  -- An invalid value is an encoder error, reported rather than sent.
  drum_commit('TRK', 1, 60, 'level', 999)
  check(e.status:find('ERROR', 1, true),
    'an out-of-range value must be reported, got ' .. e.status)
  H.pass('a drum edit previews by (map, note, parameter) and survives a bad route (15 cases)')
end

-- drum insert: clearing and retention -------------------------------------------------

do
  local calls = {}
  local result = { true, nil }
  local e = env({
    channels = fresh_channels(),
    inserter = {
      insert_drum = function(_, take, mode, note, id, value, shown)
        calls[#calls + 1] = { take = take, mode = mode, note = note,
                              id = id, value = value, shown = shown }
        return result[1], result[2]
      end,
    },
    reaper = { time_precise = function() return 0 end },
  })
  local _, _, _, insert_drum_pending = H.lift(
    { 'drum_display', 'set_status', 'drum_pending_list', 'insert_drum_pending' },
    e, FILE)

  -- Nothing pending: Insert reports and writes nothing.
  insert_drum_pending('TAKE', 1)
  check(#calls == 0, 'Insert with nothing pending must not reach the take')
  check(e.status ~= '', 'and must say so')

  -- A successful Insert clears that note's snapshot, and passes the edit's
  -- OWN map and note rather than whatever the panel is showing now.
  e.drum_maps[1].pending = { [60] = { id = 'level', value = 100, mode = 1, note = 60 } }
  e.drum_maps[2].pending = { [38] = { id = 'pan', value = -10, mode = 2, note = 38 } }
  insert_drum_pending('TAKE', 1)
  check(#calls == 1, 'Insert must reach the inserter')
  check(calls[1].mode == 1 and calls[1].note == 60 and calls[1].id == 'level'
        and calls[1].value == 100,
    'it must pass the pending map, note, parameter and value')
  check(calls[1].shown == '100', 'and the displayed value for the label')
  check(next(e.drum_maps[1].pending) == nil,
    'a successful Insert must clear the snapshot')
  check(e.drum_maps[2].pending[38] ~= nil, 'and leave the other map alone')
  check(e.status:find('Inserted', 1, true), 'and must confirm, got ' .. e.status)

  -- Several notes: every one is written, in note order, and all clear.
  calls = {}
  e.drum_maps[1].pending = {
    [42] = { id = 'reverb', value = 20, mode = 1, note = 42 },
    [36] = { id = 'level', value = 90, mode = 1, note = 36 },
    [38] = { id = 'pan', value = 5, mode = 1, note = 38 },
  }
  insert_drum_pending('TAKE', 1)
  check(#calls == 3, 'every pending note must be inserted, got ' .. #calls)
  check(calls[1].note == 36 and calls[2].note == 38 and calls[3].note == 42,
    'in note order')
  check(next(e.drum_maps[1].pending) == nil, 'and all must clear')
  check(e.status == 'Inserted Drum 1, 3 notes', 'with one summary, got ' .. e.status)

  -- A failed Insert KEEPS it and everything after it, so the user can
  -- correct the context and retry.
  result = { false, 'no take' }
  e.drum_maps[1].pending = {
    [42] = { id = 'reverb', value = 20, mode = 1, note = 42 },
    [43] = { id = 'level', value = 20, mode = 1, note = 43 },
  }
  insert_drum_pending('TAKE', 1)
  check(e.drum_maps[1].pending[42] ~= nil, 'a failed Insert must retain the snapshot')
  check(e.drum_maps[1].pending[42].id == 'reverb', 'and must not alter it')
  check(e.drum_maps[1].pending[43] ~= nil, 'nor drop what came after it')
  check(e.status:find('failed', 1, true), 'and must report, got ' .. e.status)

  -- A switch's label reads as a state, matching what the footer showed.
  result = { true, nil }
  e.drum_maps[2].pending = { [60] = { id = 'rx_note_off', value = 0, mode = 2, note = 60 } }
  insert_drum_pending('TAKE', 2)
  check(calls[#calls].shown == 'Off',
    'a switch label must read as a state, got ' .. tostring(calls[#calls].shown))
  H.pass('drum Insert writes every pending note, clears on success, retains on failure (19 cases)')
end

-- drum session state ---------------------------------------------------------------------

do
  local e = env({ channels = fresh_channels() })
  local _, drum_note, _, capture_state, restore_state = H.lift(
    { 'drum_kit_of', 'drum_note', 'valid_voice', 'capture_state', 'restore_state' }, e, FILE)

  -- Only notes that exist are saved. The table is sparse by design.
  drum_note(1, 60).level = 40
  drum_note(1, 60).pan = -20
  drum_note(2, 38).reverb = 64
  e.drum_maps[1].selected_note = 60
  e.drum_maps[2].selected_note = 38

  local st = capture_state()
  check(type(st.drum_maps) == 'table', 'the maps must be captured')
  check(st.drum_maps['1'].selected_note == 60, 'each map keeps its selected note')
  check(st.drum_maps['2'].selected_note == 38, 'independently of the other')
  check(st.drum_maps['1'].notes['60'].level == 40, 'edited values are captured')
  check(st.drum_maps['1'].notes['60'].pan == -20, 'field by field')
  check(st.drum_maps['2'].notes['38'].reverb == 64, 'on both maps')
  check(st.drum_maps['1'].notes['38'] == nil,
    'a note untouched on this map must not be stored')
  check(st.drum_maps['2'].notes['60'] == nil, 'nor on the other')

  -- What is NOT saved: a pending edit is transient by contract.
  e.drum_maps[1].pending = { [60] = { id = 'level', value = 1, mode = 1, note = 60 } }
  local json = require 'json'
  check(not json.encode(capture_state().drum_maps):find('pending', 1, true),
    'a pending drum edit must never be written to session state')

  -- A restore is passive, per map, and creates no pending edit.
  e.drum_maps = fresh_drum_maps()
  check(restore_state(st) == true, 'a well-formed record must restore')
  check(e.drum_maps[1].selected_note == 60, 'the selected note comes back')
  check(drum_note(1, 60).level == 40, 'and the shared values with it')
  check(drum_note(1, 60).pan == -20, 'every field of them')
  check(drum_note(2, 38).reverb == 64, 'on both maps')
  check(next(e.drum_maps[1].pending) == nil, 'a restore must not create a pending edit')
  check(next(e.drum_maps[2].pending) == nil, 'on either map')

  -- A note that was never saved keeps its seed rather than someone else's
  -- values: the two maps do not leak into each other.
  check(drum_note(2, 60).level == D.seed_values(60, 0, 4).level,
    'an unsaved note must fall back to its kit seed')

  -- Invalid values are DROPPED, not clamped, and the seed stands in.
  e.drum_maps = fresh_drum_maps()
  restore_state({ channels = {}, drum_maps = { ['1'] = { notes = { ['60'] = {
    level = 999,        -- above its range
    pitch = -99,        -- below its range (-60 is the floor)
    pan = 'x',          -- not a number
    reverb = 64,        -- valid, and must survive alongside the rest
    nonesuch = 7,       -- an unknown field, ignored for forward compat
  } } } } })
  -- The fixture's kits are program change 0, so that is the seed a
  -- dropped value falls back to.
  local seed = D.seed_values(60, 0, 4)
  check(drum_note(1, 60).level == seed.level,
    'an out-of-range value must be dropped, not clamped')
  check(drum_note(1, 60).pitch == seed.pitch, 'and below-range too')
  check(drum_note(1, 60).pan == seed.pan, 'and a non-number')
  check(drum_note(1, 60).reverb == 64, 'a valid sibling must still restore')
  check(drum_note(1, 60).nonesuch == nil, 'an unknown field must be ignored')

  -- Unknown maps and impossible notes are ignored rather than fatal.
  e.drum_maps = fresh_drum_maps()
  check(restore_state({ channels = {}, drum_maps = {
    ['1'] = { notes = { ['128'] = { level = 1 }, ['-1'] = { level = 1 },
                        ['60.5'] = { level = 1 }, ['x'] = { level = 1 } } },
    ['3'] = { notes = { ['60'] = { level = 1 } } },
    ['9'] = 'not a table',
  } }) == true, 'a malformed drum record must be skipped, not fatal')
  check(next(e.drum_maps[1].notes) == nil,
    'no impossible note may be created')
  check(e.drum_maps[3] == nil, 'and no third map')

  -- A selected note outside 0..127 is ignored; the map keeps note 0.
  e.drum_maps = fresh_drum_maps()
  restore_state({ channels = {}, drum_maps = { ['1'] = { selected_note = 999 } } })
  check(e.drum_maps[1].selected_note == 0,
    'an impossible selected note must be ignored')

  -- An old session with no drum_maps field still restores everything else.
  e.drum_maps = fresh_drum_maps()
  check(restore_state({ channels = {} }) == true,
    'a record from before this feature must still restore')
  check(e.drum_maps[1].selected_note == 0, 'leaving the maps at their defaults')
  check(next(e.drum_maps[1].notes) == nil, 'and creating no notes')
  H.pass('drum maps round-trip sparsely, restore passively and drop bad data (30 cases)')
end

-- the whole tool, through a headless ImGui ------------------------------------------------

-- The same boundary test_tool_lifecycle.lua uses. Everything reports
-- "unchanged" so a frame draws the whole UI without simulating input.
-- ImGui's scope stack, as the real binding enforces it.
--
-- Closing out of order is not forgiven: ending a child while a tab bar is
-- still open inside it raises "ImGui_EndChild: Missing EndTabBar()". The
-- fakes model that, because a recovery path that unwinds in the wrong order
-- looks perfectly balanced to a counter and still fails in REAPER.
local function push(state, kind)
  state.scopes[#state.scopes + 1] = kind
end

local function pop(state, kind, fn)
  local top = state.scopes[#state.scopes]
  if top ~= kind then
    -- Name the scope ImGui is still waiting for, the way ImGui does.
    local want = top and ('End' .. top:gsub('_(%l)', function(c)
      return c:upper()
    end):gsub('^%l', string.upper)) or 'nothing'
    check(false, ('ImGui_%s: Missing %s()'):format(fn, want))
  end
  state.scopes[#state.scopes] = nil
end

-- A distinct power of two per flag name, so ORing them together produces a
-- number the editor can combine without the fake having to know the real
-- ReaImGui values.
local flag_bits, next_flag_bit = {}, 0
local function flag_bit(key)
  if not flag_bits[key] then
    flag_bits[key] = 1 << (next_flag_bit % 32)
    next_flag_bit = next_flag_bit + 1
  end
  return flag_bits[key]
end

local function fake_imgui(state)
  local ImGui = {}
  local function unchanged(_, _, value) return false, value end

  local passthrough = {
    SliderInt = unchanged, SliderDouble = unchanged,
    Checkbox = function(_, label, value)
      state.checkboxes[#state.checkboxes + 1] =
        { label = label, disabled = state.disable_depth > 0 }
      state.last_item = label
      return false, value
    end,
    Button = function(_, label)
      state.buttons[#state.buttons + 1] =
        { label = label, disabled = state.disable_depth > 0 }
      return false
    end,
    BeginChild = function()
      state.child_depth = state.child_depth + 1
      push(state, 'child')
      return true
    end,
    EndChild = function()
      state.child_depth = state.child_depth - 1
      check(state.child_depth >= 0, 'EndChild without a BeginChild')
      -- ImGui reports the scope it still wants closed, not the one being
      -- asked for: "ImGui_EndChild: Missing EndTabBar()".
      pop(state, 'child', 'EndChild')
    end,
    BeginTable = function(_, id, cols)
      state.tables[#state.tables + 1] = { id = id, cols = cols }
      push(state, 'table')
      return true
    end,
    EndTable = function() pop(state, 'table', 'EndTable') end,
    TableSetupColumn = function(_, label)
      state.columns[#state.columns + 1] = label
    end,
    BeginTabBar = function()
      state.tab_bars = state.tab_bars + 1
      push(state, 'tab_bar')
      return true
    end,
    BeginTabItem = function(_, label, _, flags)
      state.tabs[#state.tabs + 1] = label
      state.tab_disabled[label] = state.disable_depth > 0
      -- SetSelected switches tab the way the real one does, from this frame.
      if flags and flags ~= 0 and flags == ImGui.TabItemFlags_SetSelected then
        state.selected_tab = label
      end
      local open = label == state.selected_tab
      if open then push(state, 'tab_item') end
      return open
    end,
    EndTabBar = function() pop(state, 'tab_bar', 'EndTabBar') end,
    EndTabItem = function() pop(state, 'tab_item', 'EndTabItem') end,
    End = function()
      check(state.child_depth == 0,
        'ImGui_End: Must call EndChild() and not End()!')
      check(#state.scopes == 0,
        'ImGui_End: scope left open: ' .. tostring(state.scopes[#state.scopes]))
    end,
    Begin = function(_, title)
      state.begins = state.begins + 1
      state.title = title
      state.fonts_at_begin = state.pushed_fonts - state.popped_fonts
      state.styles_at_begin = state.pushed_colors - state.popped_colors
      -- Per-frame, not cumulative: "how many times was this group drawn"
      -- only means something within one frame, and the tool draws several.
      state.groups = {}
      state.frame_texts = {}
      state.tables = {}
      state.columns = {}
      state.trees = {}
      state.slider_ids = {}
      state.pages = {}
      state.buttons = {}
      state.checkboxes = {}
      state.combos = {}
      state.tabs = {}
      return state.visible, state.open
    end,
  }
  for k, v in pairs(passthrough) do ImGui[k] = v end

  ImGui.CreateContext = function()
    state.contexts = state.contexts + 1
    return 'ctx-' .. state.contexts
  end
  ImGui.CreateFont = function()
    state.fonts_created = state.fonts_created + 1
    return 'font'
  end
  ImGui.Attach = function() state.fonts_attached = state.fonts_attached + 1 end
  ImGui.PushFont = function() state.pushed_fonts = state.pushed_fonts + 1 end
  ImGui.PopFont = function() state.popped_fonts = state.popped_fonts + 1 end
  ImGui.PushStyleColor = function() state.pushed_colors = state.pushed_colors + 1 end
  ImGui.PopStyleColor = function(_, n) state.popped_colors = state.popped_colors + n end
  ImGui.PushStyleVar = function() state.pushed_vars = state.pushed_vars + 1 end
  ImGui.PopStyleVar = function(_, n) state.popped_vars = state.popped_vars + n end
  ImGui.BeginDisabled = function()
    state.disable_depth = state.disable_depth + 1
    state.disabled_ever = true
    push(state, 'disabled')
  end
  ImGui.EndDisabled = function()
    state.disable_depth = state.disable_depth - 1
    check(state.disable_depth >= 0, 'EndDisabled without a BeginDisabled')
    pop(state, 'disabled', 'EndDisabled')
  end
  ImGui.Text = function(_, text)
    -- Text is an item too: drawing it makes it the LAST item, and every
    -- IsItem* query then describes it rather than the widget before it.
    state.last_item = 'text'
    state.texts[#state.texts + 1] = tostring(text)
    state.frame_texts[#state.frame_texts + 1] = tostring(text)
    -- The loop catches a throwing frame and puts it on the status line, so a
    -- crash inside frame() is observable here rather than silently swallowed.
    if tostring(text):find('ERROR') then state.error = tostring(text) end
  end
  ImGui.SeparatorText = function(_, text)
    state.groups[#state.groups + 1] = tostring(text)
  end

  -- The sidebar pages, and which one the test asks to be showing. Returning
  -- true for the selected page is what makes a page change observable.
  ImGui.Selectable = function(_, label, selected)
    state.pages[#state.pages + 1] = label
    if state.click_voice and label:find(state.click_voice, 1, true) then
      state.click_voice = nil
      return true
    end
    -- Drawn inside the sidebar child, so this throws with a child open --
    -- which is the situation the recovery path exists for.
    if state.throw_in_child then error(state.throw_in_child, 0) end
    return state.click_page == label
  end

  -- The channel picker. Returns no change unless the test asked for one, and
  -- only on the frame it asked for: a Combo that reported a change every
  -- frame would latch the override the moment the window opened.
  ImGui.Combo = function(_, label, current, items, items_sz)
    state.combos[#state.combos + 1] =
      { label = label, current = current, items = items, items_sz = items_sz,
        disabled = state.disable_depth > 0 }
    state.last_item = label
    if state.pick_combo == label then
      state.pick_combo = nil
      return true, state.pick_combo_to or 0
    end
    local pick = state.pick
    if pick and label == '##channel' then
      state.pick = nil
      return true, pick - 1
    end
    return false, current
  end

  ImGui.SliderInt = function(_, id, v, lo, hi)
    state.slider_ids[#state.slider_ids + 1] = id
    state.last_slider = id
    state.last_item = id
    if state.settle_id == id then return true, state.settle_to or v end
    return false, v
  end
  ImGui.SliderDouble = function(_, id, v)
    state.slider_ids[#state.slider_ids + 1] = id
    state.last_item = id
    return false, v
  end

  -- Text input returns (changed, buffer); the fallback's single string
  -- return would look like a change to a nil buffer.
  -- Tree nodes are open when the test says so, so a voice behind two
  -- collapsed levels can be reached. Open by default, since most tests want
  -- to see everything that would be drawn.
  ImGui.TreeNode = function(_, label)
    state.trees[#state.trees + 1] = label
    if state.closed_trees then return false end
    return true
  end
  ImGui.TreePop = function() end
  ImGui.SetNextItemOpen = function() end

  ImGui.BeginPopup = function(_, id)
    if state.open_popup ~= id then return false end
    push(state, 'popup')
    return true
  end
  ImGui.EndPopup = function() pop(state, 'popup', 'EndPopup') end
  ImGui.OpenPopup = function(_, id) state.popups[#state.popups + 1] = id end
  ImGui.CloseCurrentPopup = function() end

  ImGui.InputTextWithHint = function(_, _, _, cur) return false, cur end
  ImGui.InputText = function(_, _, cur) return false, cur end

  ImGui.CalcTextSize = function(_, text) return #(text or '') * 7, 14 end

  -- Layout calls the panel actually makes. Stubbing these through the
  -- __index fallback hid a whole class of bug: the fallback accepts any
  -- arguments and returns a string, so a wrong argument COUNT or a nil
  -- argument passed straight through without complaint.
  ImGui.SetCursorPos = function(_, x, y)
    check(type(x) == 'number' and x == x,
      'SetCursorPos x must be a number, got ' .. tostring(x))
    check(type(y) == 'number' and y == y,
      'SetCursorPos y must be a number, got ' .. tostring(y))
    state.cursor_x, state.cursor_y = x, y
  end
  ImGui.SetNextItemWidth = function(_, w)
    check(type(w) == 'number' and w == w,
      'SetNextItemWidth must be a number, got ' .. tostring(w))
  end
  ImGui.Dummy = function(_, w, h)
    check(type(w) == 'number' and type(h) == 'number',
      'Dummy needs two numbers, got ' .. tostring(w) .. ', ' .. tostring(h))
  end
  ImGui.AlignTextToFramePadding = function() end
  ImGui.SameLine = function(_, offset, spacing)
    check(offset == nil or type(offset) == 'number',
      'SameLine offset must be a number or nil, got ' .. tostring(offset))
    check(spacing == nil or type(spacing) == 'number',
      'SameLine spacing must be a number or nil, got ' .. tostring(spacing))
  end
  ImGui.GetFrameHeight = function() return 21 end
  ImGui.GetFrameHeightWithSpacing = function() return 25 end
  ImGui.GetFontSize = function() return 14 end
  ImGui.GetContentRegionAvail = function() return 400, 300 end
  ImGui.GetCursorPos = function() return 0, 0 end
  ImGui.GetStyleVar = function() return 4, 4 end
  -- One settled edit, on the frame the test asks for. Latched off again so a
  -- single request does not settle every control on every later frame.
  ImGui.IsItemDeactivatedAfterEdit = function()
    -- Only ever true for the widget itself. Asking after some other item has
    -- been drawn describes THAT item, which is how a settle gets lost.
    if state.last_item == 'text' then return false end
    if state.settle then
      state.settle = nil
      return true
    end
    -- A named cell settles instead, so a grid commit can be traced to the
    -- row it came from.
    return state.settle_id ~= nil and state.last_item == state.settle_id
  end
  -- Hovering is per widget, like the real thing: a test names the one item
  -- the pointer is over. Without that a wheel event would reach every
  -- control on the page at once, which is exactly the bug the hover check
  -- exists to prevent.
  ImGui.IsItemHovered = function()
    return state.hover_id ~= nil and state.last_item == state.hover_id
  end
  ImGui.IsMouseDoubleClicked = function() return false end
  ImGui.IsMouseDown = function() return false end

  -- The wheel is only non-zero on the frame a test asks for it, and only
  -- while something is hovered. Returning a constant here would scroll every
  -- hovered widget on every frame forever.
  ImGui.GetMouseWheel = function()
    return state.wheel or 0
  end

  setmetatable(ImGui, {
    __index = function(_, key)
      local value
      -- Flag and enum constants are VALUES, not functions: the editor ORs
      -- them together, and a function here raises "attempt to perform
      -- bitwise operation on a function value" rather than the arity error
      -- the fallback exists to avoid.
      if key:match('Flags_') or key:match('^Col_') or key:match('^Cond_')
         or key:match('^MouseButton_') or key:match('^StyleVar_')
         or key:match('^ConfigVar_') then
        value = flag_bit(key)
        rawset(ImGui, key, value)
        return value
      end
      if key:match('^Get') or key:match('Height') or key:match('Size') then
        value = function() return 14, 14 end
      else
        value = function() return key end
      end
      rawset(ImGui, key, value)
      return value
    end,
  })
  return ImGui
end

local function fake_reaper(state)
  return {
    ImGui_GetBuiltinPath = function() return '.' end,
    get_action_context = function() return false, EDITOR .. 'x.lua' end,
    defer = function(cb) state.deferred = cb end,
    time_precise = function() return state.now end,
    GetResourcePath = function() return dir .. '/../' end,
    EnumProjects = function() return state.project end,
    GetExtState = function(section, key)
      return state.ext[section .. '\0' .. key] or ''
    end,
    SetExtState = function(section, key, value, persist)
      state.ext[section .. '\0' .. key] = value
      state.persists[#state.persists + 1] = persist
    end,

    -- The editor context, which the test varies: with no MIDI editor the
    -- whole panel must draw disabled rather than throwing.
    MIDIEditor_GetActive = function() return state.editor end,
    MIDIEditor_GetTake = function() return state.take end,
    MIDIEditor_GetSetting_int = function() return state.note_chan or 0 end,

    -- Every send path is inert. Anything that did reach the hardware would
    -- show up in state.sent, which is asserted empty.
    GetMediaItemTake_Track = function() return state.track end,
    GetSelectedTrack = function() return state.selected_track end,
    -- A route exists only when the test gives the track a hardware output.
    GetMediaTrackInfo_Value = function() return state.hwout or -1 end,
    SendMIDIMessageToHardware = function(dev, msg)
      state.sent[#state.sent + 1] = { dev = dev, msg = msg }
    end,
    GetCursorPosition = function() return 0 end,
    MIDI_GetPPQPosFromProjTime = function() return 0 end,
    MIDI_GetPPQPosFromProjQN = function(_, qn) return qn * 960 end,
    MIDI_CountEvts = function() return true, 0, 0, 0 end,
    Undo_BeginBlock = function() end,
    Undo_EndBlock = function() end,
    MIDI_Sort = function() end,
  }
end

local function drive(opts)
  opts = opts or {}
  local state = {
    contexts = 0, begins = 0, tab_bars = 0, child_depth = 0, scopes = {},
    throw_in_child = opts.throw_in_child,
    fonts_created = 0, fonts_attached = 0,
    pushed_fonts = 0, popped_fonts = 0,
    pushed_colors = 0, popped_colors = 0,
    pushed_vars = 0, popped_vars = 0,
    disable_depth = 0, disabled_ever = false,
    buttons = {}, texts = {}, groups = {}, checkboxes = {}, tabs = {},
    pages = {}, click_page = opts.click_page, frame_texts = {},
    click_voice = opts.click_voice, popups = {},
    tables = {}, columns = {}, slider_ids = {},
    open_popup = opts.open_popup, trees = {},
    pick_combo = opts.pick_combo, pick_combo_to = opts.pick_combo_to,
    closed_trees = opts.closed_trees,
    settle_id = opts.settle_id, settle_to = opts.settle_to,
    hover_id = opts.hover_id, wheel = opts.wheel,
    combos = {}, pick = opts.pick,
    tab_disabled = {},
    sent = {}, persists = {},
    ext = opts.ext or {},
    project = opts.project or 'proj-A',
    visible = true, open = true,
    editor = opts.editor, take = opts.take,
    track = opts.track, selected_track = opts.selected_track,
    hwout = opts.hwout,
    note_chan = opts.note_chan,
    selected_tab = opts.selected_tab or 'Part Controls',
    now = 0, closes = 0,
  }

  local ImGui = fake_imgui(state)
  package.loaded.imgui = nil
  package.preload.imgui = function()
    return function(version)
      check(version == '0.10', 'the tool must ask for ReaImGui 0.10')
      return ImGui
    end
  end

  _G.reaper = fake_reaper(state)
  _G.PAGER_TOOL = true

  -- A fresh copy of every editor module: the tool keeps its values in
  -- file-scope tables, so a second require would hand back the first run's
  -- state and make a restore untestable.
  for name in pairs(package.loaded) do
    if name:match('^[a-z_]+$') and name ~= 'harness' then
      package.loaded[name] = nil
    end
  end

  local tool = assert(loadfile(EDITOR .. FILE))()
  check(type(tool) == 'table' and type(tool.start) == 'function',
    FILE .. ' must return a module exposing start(on_close)')
  check(state.deferred == nil, 'requiring the module must not open a window')

  tool.start(function() state.closes = state.closes + 1 end)
  check(state.deferred, 'start() must schedule a frame')

  state.deferred()
  -- A second frame, so an error raised on the first is on the status line
  -- where ImGui.Text can see it.
  if not opts.one_frame then state.deferred() end
  if opts.keep_open then return state, tool end

  state.open = false
  state.deferred()
  return state, tool
end

-- Which parameter rows a run drew. Rows are labelled with ImGui.Text now
-- that the groups have no headers of their own, so a control is "drawn" when
-- its name was printed.
local function drew_row(st, name)
  for _, t in ipairs(st.frame_texts) do
    if t == name then return true end
  end
  return false
end

-- Every group must sit on exactly one sidebar page.
--
-- This replaces the old "every group is drawn" check, which worked only
-- because each group printed a header. A group on no page would now be
-- silently unreachable -- no header is missing, the rows simply never appear.
do
  local pages = H.table_body('PAGES', FILE)
  -- Page NAMES share spelling with some group names ('Filter', 'Tuning'),
  -- so read only the `groups = { ... }` lists and ignore `name =`.
  local counted = {}
  for list in pages:gmatch('groups%s*=%s*{(.-)}') do
    for group in list:gmatch("'([^']+)'") do
      counted[group] = (counted[group] or 0) + 1
    end
  end
  for _, g in ipairs(P.GROUPS) do
    check(counted[g] == 1,
      ('group %s must appear on exactly one sidebar page, got %s')
        :format(g, tostring(counted[g])))
  end
  H.pass('every Part group sits on exactly one sidebar page (6 cases)')
end

-- The editor owns both control families, and each tab draws only its own.
--
-- `note_chan = 9` selects Part 10, which is DRUM 1 at power-on -- so it is
-- the natural fixture for an editable drum panel, and Part 1 (note_chan 0)
-- is the natural one for a normal tone Part.
do
  local part = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                       selected_tab = 'Part Controls' })
  check(table.concat(part.tabs, ' | ') == 'Overview | Part Controls | Drum Overview | Drum Controls',
    'the editor must offer Overview, Part Controls, Drum Overview then Drum Controls, got ' ..
    table.concat(part.tabs, ' | '))
  -- The first sidebar page is showing, so its rows are the ones on screen.
  check(drew_row(part, 'Level'), 'the Part Controls tab must draw its rows')
  check(#part.pages > 0, 'and must offer the sidebar pages')

  local drum = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                       note_chan = 9, selected_tab = 'Drum Controls' })
  check(table.concat(drum.tabs, ' | ') == 'Overview | Part Controls | Drum Overview | Drum Controls',
    'both tabs must remain available from the Drum page')

  -- The Part Controls sidebar belongs to the other tab and must not appear
  -- here: a drum map is not browsed by page.
  check(#drum.pages == 0,
    'the Drum tab must not draw the Part sidebar, got ' ..
    table.concat(drum.pages, ' | '))

  -- Nor any Part-only row. 'Level' is shared by both families, so the rows
  -- that exist only on the Part side are what distinguish them.
  for _, only_part in ipairs({ 'Cutoff', 'Resonance', 'Use For Rhythm',
                               'Bend Range', 'Portamento' }) do
    check(not drew_row(drum, only_part),
      'the Drum tab must not draw the Part row ' .. only_part)
  end

  local no_editor = drive({ selected_tab = 'Drum Controls' })
  check(no_editor.tab_disabled['Part Controls'] == false and
        no_editor.tab_disabled['Drum Controls'] == false,
    'tab navigation must remain available without an active MIDI editor')
  H.pass('Part and Drum tabs draw their own controls and nothing else (10 cases)')
end

-- the Drum Controls panel ----------------------------------------------------------

-- Every drum widget drawn in one frame, by its id. The rows use stable keys
-- containing the map, the note and the parameter, so this is also how a test
-- proves a note change moved the widgets rather than reusing one id.
-- Only the drum widgets: the footer's Use SysEx? checkbox is drawn on every
-- tab and is not one of this panel's controls.
local function drum_widgets(st)
  local out = {}
  for _, id in ipairs(st.slider_ids) do
    if id:find('##drum-', 1, true) then out[#out + 1] = id end
  end
  for _, c in ipairs(st.checkboxes) do
    if c.label:find('##drum-', 1, true) then out[#out + 1] = c.label end
  end
  return out
end

local function has_widget(st, id)
  for _, w in ipairs(drum_widgets(st)) do
    if w == id then return true end
  end
  return false
end

-- The note combo as it was drawn, or nil if it was not.
local function note_combo(st)
  for _, c in ipairs(st.combos) do
    if c.label == '##drum-note' then return c end
  end
  return nil
end

-- A DRUM 1 Part with a route: everything is enabled.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Controls' })
  check(not st.error, 'the drum panel threw: ' .. tostring(st.error))

  -- Seven sliders and two checkboxes, in the accepted order.
  local ORDER = { 'pitch', 'level', 'assign_group', 'pan',
                  'reverb', 'chorus', 'delay', 'rx_note_on', 'rx_note_off' }
  local widgets = drum_widgets(st)
  check(#widgets == 9, 'nine drum controls, got ' .. #widgets)
  for i, id in ipairs(ORDER) do
    local want = ('##drum-1-0-%s'):format(id)
    check(widgets[i] == want,
      ('drum control %d is %s, expected %s'):format(i, tostring(widgets[i]), want))
  end
  local sliders = 0
  for _, id in ipairs(st.slider_ids) do
    if id:find('##drum-', 1, true) then sliders = sliders + 1 end
  end
  check(sliders == 7, 'seven drum sliders, got ' .. sliders)

  -- The two Rx rows are this tab's only checkboxes; the footer's Use SysEx?
  -- is drawn on every tab and is counted separately.
  local boxes = {}
  for _, c in ipairs(st.checkboxes) do
    if c.label:find('##drum-', 1, true) then boxes[#boxes + 1] = c.label end
  end
  check(#boxes == 2, 'two drum switches, got ' .. #boxes)
  check(boxes[1] == '##drum-1-0-rx_note_on'
        and boxes[2] == '##drum-1-0-rx_note_off',
    'the two switches are the Rx rows, got ' .. table.concat(boxes, ' | '))

  -- Every label is drawn, and every one of them is a drum label.
  for _, name in ipairs({ 'Pitch', 'Level', 'Assign Group', 'Pan', 'Reverb',
                          'Chorus', 'Delay', 'Rx Note On', 'Rx Note Off' }) do
    check(drew_row(st, name), 'the drum row ' .. name .. ' must be drawn')
  end
  check(drew_row(st, 'Note'), 'the note selector must be labelled')

  -- Enabled, because this Part has a map and the track has a route.
  for _, c in ipairs(st.checkboxes) do
    if c.label:find('drum', 1, true) then
      check(not c.disabled, c.label .. ' must be enabled on a drum Part')
    end
  end
  H.pass('a routed DRUM 1 Part draws nine enabled controls in order (24 cases)')
end

-- The note combo is numeric 0..127 and nothing else.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Controls' })
  local combo = note_combo(st)
  check(combo, 'the note selector must be drawn')
  check(combo.current == 0, 'it opens on note 0, got ' .. tostring(combo.current))

  -- ReaImGui 0.10 splits the list by the byte length it is given rather than
  -- stopping at the first NUL, so the size is not optional: without it the
  -- list is a single empty entry.
  check(type(combo.items_sz) == 'number' and combo.items_sz == #combo.items,
    'the combo must pass its explicit byte length')

  local names = {}
  for entry in combo.items:gmatch('([^%z]+)') do names[#names + 1] = entry end
  check(#names == 128, 'the list holds 128 notes, got ' .. #names)
  check(names[1] == '0' and names[128] == '127',
    'the endpoints are 0 and 127, got ' .. names[1] .. ' and ' .. names[128])
  for i, name in ipairs(names) do
    check(name == tostring(i - 1),
      ('entry %d is %s, expected the plain number %d'):format(i, name, i - 1))
    check(not name:find('%a'),
      'no note names or instrument names belong in the list, got ' .. name)
  end
  H.pass('the note selector is numeric 0..127 with an explicit size (261 cases)')
end

-- A normal tone Part: the complete panel is drawn, and disabled.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 0, selected_tab = 'Drum Controls' })
  check(not st.error, 'the disabled drum panel threw: ' .. tostring(st.error))

  -- Visible: all nine, drawn from DRUM 1's values as the inert display
  -- source, rather than an empty tab.
  check(#drum_widgets(st) == 9,
    'a normal Part still draws all nine controls, got ' .. #drum_widgets(st))
  check(#drum_widgets(st) - 2 == 7, 'including its seven sliders')
  check(note_combo(st) ~= nil, 'and the note selector')
  for _, name in ipairs({ 'Pitch', 'Assign Group', 'Rx Note Off' }) do
    check(drew_row(st, name), name .. ' must still be drawn')
  end

  -- Inert: every drum widget is inside a disabled scope.
  local checked = 0
  for _, c in ipairs(st.checkboxes) do
    if c.label:find('drum', 1, true) then
      check(c.disabled, c.label .. ' must be disabled on a normal Part')
      checked = checked + 1
    end
  end
  check(checked == 2, 'both switches must have been seen, got ' .. checked)
  check(note_combo(st).disabled, 'the note selector must be disabled too')

  -- And the tab itself stays navigable: it is the CONTROLS that are inert.
  check(st.tab_disabled['Drum Controls'] == false,
    'the Drum tab must remain reachable from a normal Part')
  check(st.disable_depth == 0, 'every BeginDisabled is matched by EndDisabled')
  H.pass('a normal tone Part draws the panel complete but inert (12 cases)')
end

-- No route: the panel is drawn disabled and throws no scope or arity error.
do
  local st = drive({ note_chan = 9, selected_tab = 'Drum Controls' })
  check(not st.error, 'the no-track drum panel threw: ' .. tostring(st.error))
  check(#drum_widgets(st) == 9, 'the panel is still drawn without a track')
  for _, c in ipairs(st.checkboxes) do
    if c.label:find('drum', 1, true) then
      check(c.disabled, c.label .. ' must be disabled without a route')
    end
  end
  check(st.disable_depth == 0, 'disabled scopes stay balanced')
  check(#st.scopes == 0, 'and every ImGui scope is closed')
  check(st.sent and #st.sent == 0, 'drawing must send nothing')
  H.pass('a routeless drum panel draws disabled and balanced (7 cases)')
end

-- Use SysEx? is inert while the Drum tab is up: drum encoding is always DT1.
do
  local drum = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                       note_chan = 9, selected_tab = 'Drum Controls' })
  local found
  for _, c in ipairs(drum.checkboxes) do
    if c.label == 'Use SysEx?' then found = c end
  end
  check(found, 'the Use SysEx? checkbox must still be drawn')
  check(found.disabled, 'and must be greyed while Drum Controls is active')

  -- On the Part tab, with the same route, it is live -- so the greying is
  -- the tab's doing and not the fixture's.
  local part = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                       note_chan = 9, selected_tab = 'Part Controls' })
  local live
  for _, c in ipairs(part.checkboxes) do
    if c.label == 'Use SysEx?' then live = c end
  end
  check(live and not live.disabled,
    'Use SysEx? must still be live on the Part Controls tab')
  H.pass('Use SysEx? is greyed on the Drum tab only (4 cases)')
end

-- the Drum Overview ------------------------------------------------------------------

-- Every note the kit defines, one row each, nine controls per row.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Overview' })
  check(not st.error, 'the drum overview threw: ' .. tostring(st.error))

  -- The fixture's kits are SC-8850 STANDARD 1 (LSB 4, pc 0).
  local notes = D.kit_notes(0, 4)
  check(notes and #notes > 0, 'the fixture kit must be in the factory table')
  check(#drum_widgets(st) == #notes * #D.PARAMS,
    ('one row per kit note, nine controls each: expected %d, got %d')
      :format(#notes * #D.PARAMS, #drum_widgets(st)))
  check(has_widget(st, ('##drum-1-%d-level'):format(notes[1])), 'the first note is drawn')
  check(has_widget(st, ('##drum-1-%d-rx_note_off'):format(notes[#notes])),
    'and the last')

  check(st.columns[1] == 'Note', 'the first column is the note, got ' ..
    tostring(st.columns[1]))
  check(#st.columns == 1 + #D.PARAMS, 'then one column per parameter, got ' .. #st.columns)

  for _, c in ipairs(st.checkboxes) do
    if c.label == 'Use SysEx?' then
      check(c.disabled, 'Use SysEx? is greyed on the Drum Overview too')
    elseif c.label:find('##drum-', 1, true) then
      check(not c.disabled, c.label .. ' must be enabled on a routed drum Part')
    end
  end
  check(#st.scopes == 0, 'every ImGui scope is closed')
  check(#st.sent == 0, 'drawing must send nothing')

  -- A normal tone Part: the grid is drawn, inert.
  local tone = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                       note_chan = 0, selected_tab = 'Drum Overview' })
  check(not tone.error, 'the inert drum overview threw: ' .. tostring(tone.error))
  check(#drum_widgets(tone) == #notes * #D.PARAMS, 'a tone Part still draws the grid')
  for _, c in ipairs(tone.checkboxes) do
    if c.label:find('##drum-', 1, true) then
      check(c.disabled, c.label .. ' must be disabled on a tone Part')
    end
  end
  H.pass('the Drum Overview draws every kit note, enabled only on a drum Part')
end

-- Clicking a Part number on the Overview opens that Part on Part Controls.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 0, selected_tab = 'Overview',
                     click_page = '5##part-row-5', one_frame = true,
                     keep_open = true })
  check(not st.error, 'clicking a Part threw: ' .. tostring(st.error))
  check(st.selected_tab == 'Part Controls',
    'the click must switch to Part Controls, got ' .. tostring(st.selected_tab))
  st.click_page = nil
  -- Two frames: the header learns the tab changed one frame late, by design.
  st.deferred()
  st.deferred()
  local picker
  for _, c in ipairs(st.combos) do
    if c.label == '##channel' then picker = c end
  end
  check(picker and picker.current == 4,
    'the header must now name Part 5, got ' .. tostring(picker and picker.current))
  check(#st.sent == 0, 'and nothing is sent')
  check(#st.scopes == 0, 'with every scope closed')
  H.pass('an Overview Part click opens it on Part Controls (4 cases)')
end

-- Clicking a note number opens that note on Drum Controls.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Overview',
                     click_page = '36##drum-row-36', one_frame = true,
                     keep_open = true })
  check(not st.error, 'clicking a note threw: ' .. tostring(st.error))
  check(st.selected_tab == 'Drum Controls',
    'the click must switch to Drum Controls, got ' .. tostring(st.selected_tab))
  st.click_page = nil
  st.deferred()
  local combo = note_combo(st)
  check(combo and combo.current == 36,
    'showing the clicked note, got ' .. tostring(combo and combo.current))
  check(#st.sent == 0, 'and sending nothing')
  check(#st.scopes == 0, 'with every scope closed')
  H.pass('a Drum Overview note click opens it on Drum Controls (4 cases)')
end

-- A settled cell previews, becomes insertable, and only edited notes persist.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Overview',
                     settle_id = '##drum-1-36-level', settle_to = 100,
                     keep_open = true })
  check(not st.error, 'settling a grid cell threw: ' .. tostring(st.error))
  check(#st.sent >= 1, 'a settled cell must preview')

  local pending_shown = false
  for _, t in ipairs(st.frame_texts) do
    if t == 'Pending: Drum 1 Note 36 Level 100' then pending_shown = true end
  end
  check(pending_shown, 'the footer must name the edited note')
  local insert
  for _, b in ipairs(st.buttons) do
    if b.label == 'Insert' then insert = b end
  end
  check(insert and not insert.disabled, 'and Insert must be live')

  -- Close, which saves the session. Only the edited note is stored: forty
  -- rows looked at must not become forty saved notes.
  st.open = false
  st.deferred()
  local saved = ''
  for _, v in pairs(st.ext) do saved = saved .. v end
  local json = require 'json'
  local rec = json.decode(saved)
  local notes = rec and rec.state and rec.state.drum_maps['1'].notes
  check(notes and notes['36'] and notes['36'].level == 100,
    'the edited note must be saved, got ' .. saved:sub(1, 200))
  local n = 0
  for _ in pairs(notes or {}) do n = n + 1 end
  check(n == 1, 'and only that note, got ' .. n)
  H.pass('a Drum Overview edit previews, is insertable, and persists alone (6 cases)')
end

-- A settled drum slider previews once, correctly addressed.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Controls',
                     settle_id = '##drum-1-0-level', settle_to = 100,
                     keep_open = true })
  check(not st.error, 'settling a drum slider threw: ' .. tostring(st.error))

  -- One message, framed, to the routed device. The value 100 at note 0 on
  -- DRUM 1 Level is address 41 02 00 -- transcribed here rather than
  -- derived, the same way the encoder tests pin it.
  check(#st.sent == 1, 'one drum preview must have gone out, got ' .. #st.sent)
  local msg = st.sent[1].msg
  check(msg:byte(1) == 0xF0 and msg:byte(#msg) == 0xF7,
    'the SysEx must be framed at the send boundary')
  local body = { msg:byte(2, #msg - 1) }
  local want = { 0x41, 0x10, 0x42, 0x12, 0x41, 0x02, 0x00, 0x64, 0x59 }
  for i, b in ipairs(want) do
    check(body[i] == b,
      ('preview byte %d is %s, expected %02X'):format(i, tostring(body[i]), b))
  end
  H.pass('a settled drum slider previews one correctly addressed write (12 cases)')
end

-- Selecting a note sends nothing and creates no pending edit.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Controls',
                     pick_combo = '##drum-note', pick_combo_to = 60,
                     keep_open = true })
  check(not st.error, 'picking a note threw: ' .. tostring(st.error))
  check(#st.sent == 0, 'selecting a note must send nothing, got ' .. #st.sent)

  -- The panel followed the pick: the widgets are keyed to note 60 now, which
  -- is also what keeps a double-click on one note from resetting another.
  check(has_widget(st, '##drum-1-60-level'),
    'the rows must follow the selected note')
  check(not has_widget(st, '##drum-1-0-level'),
    'and must no longer draw the old note')
  check(note_combo(st).current == 60,
    'the combo must show the new note, got ' .. tostring(note_combo(st).current))
  H.pass('selecting a note only changes what is shown (5 cases)')
end

-- The wheel steps the note while the combo is hovered ------------------------------

-- 128 entries is a long list to open and scroll, and stepping through
-- neighbouring notes is how a drum kit is actually auditioned. The rule is
-- the Effects Editor's: wheel up moves toward the TOP of the list, which is
-- the lower index.

-- Wheel up, from note 0: already at the top, so nothing moves.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Controls',
                     hover_id = '##drum-note', wheel = 1, keep_open = true })
  check(not st.error, 'wheeling at the top threw: ' .. tostring(st.error))
  check(note_combo(st).current == 0,
    'note 0 must not step below the range, got ' .. tostring(note_combo(st).current))
  check(has_widget(st, '##drum-1-0-level'), 'and the rows must stay on note 0')
end

-- Wheel down: one step up the note numbers.
--
-- The ROWS are what say where the note actually is. The combo is drawn
-- before the wheel is read -- IsItemHovered describes the last item, so the
-- query can only come after the widget -- so within one frame the combo
-- still shows the note it opened on and the rows below it show the stepped
-- one. That is ordinary ImGui: the combo catches up on the next frame, which
-- is invisible at frame rate.
--
-- drive() runs two frames, so a held wheel steps twice: 0 -> 1 -> 2.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Controls',
                     hover_id = '##drum-note', wheel = -1, keep_open = true })
  check(not st.error, 'wheeling down threw: ' .. tostring(st.error))
  check(has_widget(st, '##drum-1-2-level'),
    'two frames of wheel must step the note twice, got ' ..
    table.concat(drum_widgets(st), ' '))
  check(not has_widget(st, '##drum-1-0-level'),
    'and must leave the starting note behind')
  -- The combo trails by exactly one frame, never more.
  check(note_combo(st).current == 1,
    'the combo must show the previous frame\'s note, got ' ..
    tostring(note_combo(st).current))
end

-- One notch is one note: a third frame advances by exactly one more.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Controls',
                     hover_id = '##drum-note', wheel = -1, keep_open = true })
  st.deferred()
  check(has_widget(st, '##drum-1-3-level'),
    'each frame must step exactly one note, got ' ..
    table.concat(drum_widgets(st), ' '))
end

-- A wheel with nothing hovered changes nothing. Without the hover check a
-- notch anywhere on the page would move the note.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Controls',
                     wheel = -1, keep_open = true })
  check(note_combo(st).current == 0,
    'an unhovered wheel must not move the note, got ' ..
    tostring(note_combo(st).current))
end

-- Nor does a wheel over one of the SLIDERS. The sliders have their own drag
-- behaviour and must not double as a note selector.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Controls',
                     hover_id = '##drum-1-0-level', wheel = -1,
                     keep_open = true })
  check(note_combo(st).current == 0,
    'hovering a slider must not step the note, got ' ..
    tostring(note_combo(st).current))
end

-- Stepping sends nothing and creates no pending edit: it is a selection,
-- exactly like picking from the list.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Drum Controls',
                     hover_id = '##drum-note', wheel = -1, keep_open = true })
  check(#st.sent == 0,
    'stepping the note must send nothing, got ' .. #st.sent)
  -- Nothing pending means Insert stays disabled, which is what the footer
  -- reports. A pending edit created here would be an edit the user never made.
  local insert
  for _, b in ipairs(st.buttons) do
    if b.label == 'Insert' then insert = b end
  end
  check(insert and insert.disabled,
    'and must leave Insert disabled, with nothing pending')
end

-- A disabled panel does not scroll. A normal tone Part is displaying DRUM 1's
-- values inertly; moving its note would be an edit to a map the user is not
-- editing.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 0, selected_tab = 'Drum Controls',
                     hover_id = '##drum-note', wheel = -1, keep_open = true })
  check(note_combo(st).current == 0,
    'a normal Part must not step the shared note, got ' ..
    tostring(note_combo(st).current))
end

-- Neither does a routeless one, which is disabled for the same reason.
do
  local st = drive({ note_chan = 9, selected_tab = 'Drum Controls',
                     hover_id = '##drum-note', wheel = -1, keep_open = true })
  check(note_combo(st).current == 0,
    'a routeless panel must not step the note, got ' ..
    tostring(note_combo(st).current))
  check(st.disable_depth == 0, 'and its disabled scopes stay balanced')
end
H.pass('the wheel steps the note only over the combo, clamped and inert when disabled (16 cases)')

-- Two Parts on one map see one set of widgets; the other map is its own.
do
  -- Part 10 and Part 11 both on DRUM 1: the widget keys name the MAP, not
  -- the Part, so both Parts address the same shared values.
  local a = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                    note_chan = 9, selected_tab = 'Drum Controls' })
  check(has_widget(a, '##drum-1-0-level'),
    'a DRUM 1 Part must draw map 1 widgets')
  check(not has_widget(a, '##drum-2-0-level'),
    'and not the other map')

  -- A DRUM 2 Part draws the other map instead. Part 11 is a normal Part at
  -- power-on, so it is moved to DRUM 2 through the session record -- which
  -- is also the shape the tool itself writes, rather than a hand-built key.
  local seed = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                       note_chan = 10, selected_tab = 'Part Controls',
                       pick_combo = '##rhythm', pick_combo_to = 2 })

  local b = drive({ ext = seed.ext, editor = 'ED', take = 'TAKE', track = 'TRK',
                    hwout = 32, note_chan = 10,
                    selected_tab = 'Drum Controls' })
  check(has_widget(b, '##drum-2-0-level'),
    'a DRUM 2 Part must draw map 2 widgets')
  check(not has_widget(b, '##drum-1-0-level'),
    'and not map 1')
  H.pass('the panel follows the Part\'s map, not the Part (4 cases)')
end

-- With no MIDI editor: the panel draws, disabled, and says why.
do
  local st = drive()

  check(st.contexts == 1, 'one context per visit, got ' .. st.contexts)
  check(st.title == 'PAGER - Part Editor',
    'the window keeps its name, got ' .. tostring(st.title))
  check(st.fonts_created == 1 and st.fonts_attached == 1,
    'one shared font is created and attached')
  check(st.fonts_at_begin == 1, 'the font is active while the window draws')
  check(st.styles_at_begin > 0, 'the theme is active while the window draws')

  -- Balanced: an unpopped font or color leaks into whatever draws next, and
  -- in REAPER that is another script's window.
  check(st.pushed_fonts == st.popped_fonts, 'the font stack is balanced')
  check(st.pushed_colors == st.popped_colors, 'the color stack is balanced')
  check(st.pushed_vars == st.popped_vars, 'the style-var stack is balanced')
  -- A frame that throws is caught by the loop and reported on the status
  -- line; it must never happen, and it must never leak a disabled scope.
  check(not st.error, 'the frame threw: ' .. tostring(st.error))
  check(st.disable_depth == 0, 'every BeginDisabled is matched by EndDisabled')

  check(st.disabled_ever, 'with no MIDI editor the panel must be disabled')
  local said = table.concat(st.texts, ' | ')
  check(said:find('No track selected', 1, true),
    'and must explain the required context, got ' .. said)

  -- The controls are drawn, not hidden, so the user can see what the tool
  -- offers. That is what makes the nil Part reachable: every row still needs
  -- a channel to read a value from, and there is no active one. Drawing them
  -- at all is the regression this asserts.
  check(drew_row(st, 'Level'),
    'the rows must still be drawn while disabled')
  check(#st.pages > 0, 'and the sidebar must still be offered')

  -- Use SysEx? is per-channel state like every slider, so it is drawn even
  -- with no active Part -- disabled, showing channel 1. Hiding it would make
  -- the one setting that changes how everything else is encoded the only
  -- control that vanishes.
  local sysex_box
  for _, b in ipairs(st.checkboxes) do
    if b.label == 'Use SysEx?' then sysex_box = b end
  end
  check(sysex_box, 'Use SysEx? must be drawn even without a MIDI editor')
  check(sysex_box.disabled, 'and must be inert without an active Part')

  -- The picker keeps the header's shape between the two states rather than
  -- vanishing, and shows Channel 1 so there is no blank control.
  local picker
  for _, c in ipairs(st.combos) do
    if c.label == '##channel' then picker = c end
  end
  check(picker, 'the channel picker must be drawn without a MIDI editor')
  check(picker.disabled, 'and must be inert without a route to send to')
  check(picker.current == 0, 'showing Channel 1, got ' .. tostring(picker.current))

  check(st.closes == 1, 'on_close fires exactly once, got ' .. st.closes)
  check(#st.sent == 0, 'a lifecycle with no user edit sends nothing')
  check(#st.persists > 0, 'closing saves state')
  for _, persist in ipairs(st.persists) do
    check(persist == false, 'state is written with persist=false')
  end
  H.pass('the tool opens, draws disabled without an editor, and closes once (16 cases)')
end

-- With a MIDI editor: every group is drawn, and the header names the Part.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32, note_chan = 9 })

  -- The first sidebar page's rows are the ones on screen.
  for _, prm in ipairs(P.PARAMS) do
    if prm.group == 'Sends and Mix' then
      check(drew_row(st, prm.name),
        'the panel must draw the ' .. prm.name .. ' row')
    end
  end

  -- The header names the Part through the picker rather than a label, so the
  -- same control that reports the channel is the one that changes it.
  local picker
  for _, c in ipairs(st.combos) do
    if c.label == '##channel' then picker = c end
  end
  check(picker, 'the header must offer a channel picker')
  check(picker.current == 9,
    "the picker must show the piano roll's Part, got " ..
    tostring(picker.current))
  check(not picker.disabled, 'and must be usable with an active Part')
  check(select(2, picker.items:gsub('%z', '')) == 16,
    'the picker must list all sixteen channels')

  -- Insert exists and is disabled, because nothing is pending on a fresh
  -- visit -- the design says so explicitly.
  local insert_seen, insert_disabled
  for _, b in ipairs(st.buttons) do
    if b.label == 'Insert' then
      insert_seen, insert_disabled = true, b.disabled
    end
  end
  check(insert_seen, 'the footer must offer Insert')
  check(insert_disabled, 'Insert must be disabled with nothing pending')

  -- With an active Part the encoding switch is live.
  local sysex_box
  for _, b in ipairs(st.checkboxes) do
    if b.label == 'Use SysEx?' then sysex_box = b end
  end
  check(sysex_box and not sysex_box.disabled,
    'Use SysEx? must be editable once a Part is active')
  check(st.disable_depth == 0, 'every BeginDisabled is matched by EndDisabled')
  check(#st.sent == 0, 'drawing must not send anything')
  H.pass('with an editor the panel draws every group and names the Part (10 cases)')
end

-- A track and no take: the panel is live, and says nothing is being written.
--
-- This is the mode the tool exists for -- auditioning a Part against the
-- hardware with no MIDI item anywhere in the project. Previewing needs a
-- route, and a route is a track property, so demanding a take was never
-- anything but an accident of how the route was resolved.
do
  local st = drive({ selected_track = 'TRK', hwout = 32, keep_open = true })

  check(not st.error, 'the frame must not throw: ' .. tostring(st.error))

  -- The controls are live: no MIDI editor, but somewhere to send.
  local picker
  for _, c in ipairs(st.combos) do
    if c.label == '##channel' then picker = c end
  end
  check(picker and not picker.disabled,
    'the channel picker must be live with a track and no take')

  local sysex_box
  for _, b in ipairs(st.checkboxes) do
    if b.label == 'Use SysEx?' then sysex_box = b end
  end
  check(sysex_box and not sysex_box.disabled,
    'Use SysEx? must be live with a track and no take')

  -- Insert is the one thing that genuinely needs a take, so it alone stays
  -- disabled -- and the header has to say why, or a greyed-out button is
  -- just a mystery.
  local insert
  for _, b in ipairs(st.buttons) do
    if b.label == 'Insert' then insert = b end
  end
  check(insert and insert.disabled,
    'Insert must stay disabled without a take to write into')

  local said = table.concat(st.texts, ' | ')
  check(said:find('Preview only', 1, true),
    'the header must say previews are not being written, got ' .. said)
  check(said:find('not writing to the project', 1, true),
    'and must say so in those terms, got ' .. said)

  st.open = false
  st.deferred()
  H.pass('a track alone drives the hardware, and the header says nothing is written (7 cases)')
end

-- A settled edit with a track and no take actually reaches the hardware.
--
-- The assertions above prove the panel is enabled; this proves the route is
-- real. Without it the whole mode could be live on screen and silent.
do
  local st = drive({ selected_track = 'TRK', hwout = 32, keep_open = true })

  -- Settle one slider: the fake reports a deactivated edit for one frame.
  st.settle = true
  st.deferred()
  -- pump() releases at most one due message per frame, so step the clock.
  st.now = st.now + 1
  st.deferred()

  check(#st.sent > 0,
    'a settled edit with a track and no take must reach the hardware')
  check(st.sent[1].dev == 1,
    'and must go to the device the track routes to, got ' ..
    tostring(st.sent[1].dev))

  st.open = false
  st.deferred()
  H.pass('a track-only edit is actually sent to the hardware (2 cases)')
end

-- The sidebar shows one page at a time, and switching changes the rows.
--
-- This is what the single-column layout costs: rows that used to be on
-- screen together are now behind a page. A page that did not actually switch
-- would look identical to one that did until the user went looking for a
-- control that was never there.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     keep_open = true })

  -- Common is showing: its rows are drawn, the Filter page's are not.
  check(drew_row(st, 'Level'), 'the Common page must draw Level')
  check(not drew_row(st, 'Cutoff'),
    "and must not draw another page's rows")

  -- Click Filter, then draw again.
  st.click_page = 'Filter'
  st.deferred()
  st.click_page = nil
  st.deferred()

  check(drew_row(st, 'Cutoff'), 'the Filter page must draw Cutoff')
  check(not drew_row(st, 'Level'),
    "and must no longer draw the Common page's rows")

  -- The pages added for the rest of the Part map each draw their rows.
  for _, c in ipairs({ { 'Keyboard', 'Rx Channel' }, { 'Keyboard', 'Key Range High' },
                       { 'Receive', 'Rx Pitch Bend' }, { 'Receive', 'Rx Bank Select LSB' },
                       { 'Common', 'Output Assign' },
                       { 'Tuning', 'Scale B' },
                       -- The matrix labels its rows by destination and the
                       -- pickers by name.
                       { 'Controllers', 'LFO1 Pitch Depth' },
                       { 'Controllers', 'CC2 Controller' } }) do
    st.click_page = c[1]
    st.deferred()
    st.click_page = nil
    st.deferred()
    check(not st.error, c[1] .. ' page threw: ' .. tostring(st.error))
    check(drew_row(st, c[2]), ('the %s page must draw %s'):format(c[1], c[2]))
  end
  st.click_page = 'Filter'
  st.deferred()
  st.click_page = nil
  st.deferred()

  -- Switching channel must not move the user off the page they are on: the
  -- page is UI state, not per-channel state.
  st.pick = 5
  st.deferred()
  st.pick = nil
  st.deferred()
  check(drew_row(st, 'Cutoff'),
    'changing channel must leave the sidebar page alone')

  st.open = false
  st.deferred()
  check(#st.sent == 0, 'navigating the sidebar must send nothing')
  H.pass('the sidebar switches pages and survives a channel change (6 cases)')
end

-- The Controllers page is GSAE's Controller Matrix: 11 destinations by 6
-- sources, every cell a real control, plus the CC1/CC2 pickers.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 0, click_page = 'Controllers',
                     settle_id = '##caf_cutoff-1', settle_to = 10,
                     keep_open = true })
  check(not st.error, 'the matrix threw: ' .. tostring(st.error))

  local found = false
  for _, t in ipairs(st.tables) do
    if t.id == 'controller-matrix' then found = t.cols == 7 end
  end
  check(found, 'one matrix table: a label column plus six sources')
  local cols = table.concat(st.columns, ' | ')
  check(cols == ' | Mod | Bend | CAf | PAf | CC1 | CC2',
    'sources across, in GSAE order, got ' .. cols)

  local cells = 0
  for _, id in ipairs(st.slider_ids) do
    if id:match('^##[%w_]+%-1$') then cells = cells + 1 end
  end
  check(cells == 66, '66 cells, got ' .. cells)
  local ids = table.concat(st.slider_ids, ' ')
  check(ids:find('##bend_range-1', 1, true),
    'the Bend Pitch Control cell is Bend Range')
  check(ids:find('##mod_lfo1_pitch-1', 1, true) and ids:find('##cc2_lfo2_tva-1', 1, true),
    'first and last sources both drawn')

  local picker = false
  for _, c in ipairs(st.combos) do
    if c.label == '##cc1_number' then picker = c.current == 16 end
  end
  check(picker, 'the CC1 picker is drawn, on CC#16')

  -- A settled cell previews and goes pending like any other control.
  check(#st.sent >= 1, 'a settled matrix cell must preview')
  local pending = false
  for _, t in ipairs(st.frame_texts) do
    if t:find('Pending:', 1, true) and t:find('CAf TVF Cutoff', 1, true) then
      pending = true
    end
  end
  check(pending, 'and must be the pending edit')
  H.pass('the Controllers page is an 11 x 6 matrix of live controls (8 cases)')
end

-- An error inside a child must be reported as itself.
--
-- The frame draws inside nested children. ImGui refuses an End() while a
-- child is open, so a throw that skips EndChild turns into "Must call
-- EndChild() and not End()" -- an error about the recovery, naming the loop's
-- own line, with the real cause gone. That is exactly the failure this
-- guards: the status line must carry what actually threw.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     keep_open = true, throw_in_child = 'boom-inside-child' })

  -- The status line is set after End() and drawn by the NEXT frame, so the
  -- throwing frame alone cannot show it. Stop throwing, then draw once more.
  st.throw_in_child = nil
  st.deferred()

  local said = table.concat(st.texts, ' | ')
  check(said:find('boom%-inside%-child'),
    'the original error must reach the status line, got ' .. said)
  check(not said:find('EndChild', 1, true),
    'and must not be replaced by an EndChild complaint, got ' .. said)
  check(st.child_depth == 0,
    'every child must be closed before End(), got ' .. tostring(st.child_depth))

  st.open = false
  st.deferred()
  H.pass('an error inside a child is reported as itself (3 cases)')
end

-- The Overview draws every Part, and locks the channel picker to Multi.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     selected_tab = 'Overview', keep_open = true })

  check(not st.error, 'the Overview must not throw: ' .. tostring(st.error))

  -- One table, with a column per grid column plus Part and Voice.
  check(#st.tables == 1, 'the Overview must draw one grid, got ' .. #st.tables)
  local cols = table.concat(st.columns, ' | ')
  for _, label in ipairs({ 'Part', 'Voice', 'M/P', 'Cut', 'Res', 'Rev', 'Cho',
                           'Dly', 'Pan', 'Level' }) do
    check(cols:find(label, 1, true),
      'the grid must offer a ' .. label .. ' column, got ' .. cols)
  end

  -- XG's Var and Dry have no SC-8850 equivalent and must not be invented.
  check(not cols:find('Var', 1, true), 'there is no Variation send on the 8850')
  check(not cols:find('Dry', 1, true), 'and no dry level')

  -- Sixteen rows, each naming its Part and its power-on voice. The voice is
  -- a button now -- it opens the picker -- so it is a button label.
  local labels = {}
  for _, b in ipairs(st.buttons) do labels[#labels + 1] = b.label end
  local said = table.concat(labels, ' | ')
  check(said:find('STANDARD 1', 1, true),
    'Part 10 is the drum Part at power-on, got ' .. said)
  check(said:find('Piano 1', 1, true), 'and the rest are Grand Piano')

  -- The picker says Multi and cannot be changed: no single Part is showing.
  local picker
  for _, c in ipairs(st.combos) do
    if c.label == '##channel' then picker = c end
  end
  check(picker, 'the header must still offer the picker on the Overview')
  check(picker.items:find('Multi', 1, true),
    'and it must read Multi, got ' .. tostring(picker.items))
  check(picker.disabled, 'and must be locked')

  st.open = false
  st.deferred()
  check(#st.sent == 0, 'drawing the Overview must send nothing')
  H.pass('the Overview grids every Part and locks the picker to Multi (14 cases)')
end

-- A grid cell edits the Part on its own row.
--
-- Every row draws the same parameters, so the row a settled edit belongs to
-- is the thing most easily lost: one shared widget id, or a commit that read
-- the header's channel instead of the row's, would send every edit to one
-- Part and look almost right.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     selected_tab = 'Overview', keep_open = true })

  -- Each cell gets its own id, or ImGui would treat sixteen rows as one
  -- widget and dragging any row would move whichever drew first.
  local ids = {}
  for _, id in ipairs(st.slider_ids) do
    check(not ids[id], 'grid cell ids must be unique, saw ' .. id .. ' twice')
    ids[id] = true
  end
  check(ids['##level-1'] and ids['##level-16'],
    'each Part must get its own cell id')

  st.open = false
  st.deferred()
  H.pass('every Overview cell has its own widget id (2 cases)')
end

-- A settled grid cell previews on ITS OWN Part, not the header's.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     selected_tab = 'Overview', keep_open = true,
                     settle_id = '##level-7', settle_to = 99 })

  check(not st.error, 'the grid edit must not throw: ' .. tostring(st.error))

  -- Level is CC7, so the preview is a Control Change on the row's channel.
  -- Channel 7 is 0x06 in the status byte: 0xB0 | 6 = 0xB6.
  st.now = st.now + 1
  st.deferred()
  check(#st.sent > 0, 'a settled grid cell must reach the hardware')
  local status = st.sent[1].msg:byte(1)
  check(status == 0xB6,
    ('the preview must go to Part 7 (0xB6), got 0x%02X'):format(status))

  st.open = false
  st.deferred()
  -- The value that went out is the one the cell settled on.
  check(st.sent[1].msg:byte(3) == 99,
    'and must carry the settled value, got ' .. tostring(st.sent[1].msg:byte(3)))
  H.pass('a grid cell edits and previews its own Part (4 cases)')
end

-- Choosing a voice sends Bank Select MSB, LSB, then Program Change.
--
-- Order is the whole point: the hardware latches Bank Select and applies it
-- when the Program Change arrives, so a PC that reaches the device before
-- its bank bytes selects out of whichever bank was last set. That failure
-- picks a real, wrong instrument rather than erroring, which is exactly the
-- kind of bug that survives a casual listen.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     selected_tab = 'Overview', keep_open = true,
                     open_popup = 'voice-7',
                     click_voice = 'Piano 2##0-4-1' })

  check(not st.error, 'choosing a voice must not throw: ' .. tostring(st.error))

  -- Three messages, released one per frame by the queue's pacing.
  for _ = 1, 4 do
    st.now = st.now + 1
    st.deferred()
  end
  check(#st.sent == 3,
    'a voice change is three messages, got ' .. #st.sent)

  local function bytes(i)
    local out = {}
    for j = 1, #st.sent[i].msg do
      out[#out + 1] = ('%02X'):format(st.sent[i].msg:byte(j))
    end
    return table.concat(out, ' ')
  end

  -- Part 7 is channel 6: 0xB6 for the CCs, 0xC6 for the Program Change.
  -- Piano 2 in the SC-8850 map is bank MSB 0 / LSB 4, PC 1. The LSB is what
  -- picks the map, so the same voice name in the SC-55 map would send 01.
  check(bytes(1) == 'B6 00 00', 'first Bank Select MSB, got ' .. bytes(1))
  check(bytes(2) == 'B6 20 04', 'then Bank Select LSB, got ' .. bytes(2))
  check(bytes(3) == 'C6 01', 'then Program Change, got ' .. bytes(3))

  st.open = false
  st.deferred()
  H.pass('a voice change sends bank select then program change, in order (5 cases)')
end

-- A settled edit enables Insert -- with or without a route.
--
-- Preview and Insert are independent by design: "a preview that could not be
-- routed still leaves a value that can be inserted". Gating the commit on a
-- route broke exactly that, and left Insert permanently grey on a track with
-- no hardware output -- a state with no error and no explanation.
do
  -- With a route: the ordinary case.
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     keep_open = true, settle_id = '##level' })
  st.deferred()

  local insert
  for _, b in ipairs(st.buttons) do
    if b.label == 'Insert' then insert = b end
  end
  check(insert and not insert.disabled,
    'a settled edit must enable Insert')

  local said = table.concat(st.frame_texts, ' | ')
  check(said:find('Pending:', 1, true),
    'and the footer must name what is pending, got ' .. said)

  st.open = false
  st.deferred()

  -- With NO track at all: nothing can be previewed, but the edit is still
  -- an edit and must still be insertable. This is the case the route gate
  -- broke -- a take can exist with no track selected to send through.
  local no_route = drive({ editor = 'ED', take = 'TAKE',
                           keep_open = true,
                           settle_id = '##level' })
  no_route.deferred()

  local btn
  for _, b in ipairs(no_route.buttons) do
    if b.label == 'Insert' then btn = b end
  end
  check(btn and not btn.disabled,
    'an unroutable edit must still be insertable')
  check(#no_route.sent == 0, 'and nothing must reach the hardware')

  local why = table.concat(no_route.texts, ' | ')
  check(why:find('insertable', 1, true),
    'the status must say the value was kept, got ' .. why)

  no_route.open = false
  no_route.deferred()
  H.pass('a settled edit is insertable with or without a route (5 cases)')
end

-- Part 10 is the drum Part at power-on; the rest are not.
--
-- The row's own default cannot express this -- it is one value shared by all
-- sixteen Parts -- so the one Part that differs is set when a channel is
-- built, and a change there would silently make every Part melodic.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     selected_tab = 'Overview', keep_open = true })

  check(not st.error, 'the frame must not throw: ' .. tostring(st.error))

  -- The combos the grid drew for the rhythm column, one per Part in order.
  local rhythm = {}
  for _, c in ipairs(st.combos) do
    if c.label:find('##rhythm-', 1, true) then
      rhythm[#rhythm + 1] = c
    end
  end
  check(#rhythm == 16, 'one rhythm control per Part, got ' .. #rhythm)

  for i, c in ipairs(rhythm) do
    local want = i == 10 and 1 or 0
    check(c.current == want,
      ('Part %d must start at %d, got %s'):format(i, want, tostring(c.current)))
  end

  -- Named states, not numbers: a value with no name would be unreachable.
  check(rhythm[1].items:find('DRUM 1', 1, true),
    'the choices must be named, got ' .. tostring(rhythm[1].items))

  st.open = false
  st.deferred()
  H.pass('Part 10 alone is a drum Part at power-on (19 cases)')
end

-- An Overview edit on any Part enables Insert.
--
-- The Overview edits all sixteen Parts at once, so "is anything pending"
-- cannot be answered from the header's channel -- it is locked to Multi
-- there and resolves to Part 1. An edit on row 9 left Insert grey, with the
-- edit made, previewed, and unwritable.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     selected_tab = 'Overview', keep_open = true,
                     pick_combo = '##rhythm-9', pick_combo_to = 2 })
  st.deferred()

  check(not st.error, 'the edit must not throw: ' .. tostring(st.error))

  local insert
  for _, b in ipairs(st.buttons) do
    if b.label == 'Insert' then insert = b end
  end
  check(insert and not insert.disabled,
    'an edit on any Part must enable Insert on the Overview')

  -- The footer names the Part, since the header cannot.
  local said = table.concat(st.frame_texts, ' | ')
  check(said:find('Part 9', 1, true),
    'and must name the Part it belongs to, got ' .. said)

  st.open = false
  st.deferred()
  H.pass('an Overview edit on any Part is insertable (3 cases)')
end

-- Parts sharing a drum mode share one kit.
--
-- The manual is explicit (p.55): "the same Drum Set will automatically be
-- selected for Parts that have the same Part Mode... if the Part Mode of
-- both Parts 10 and 11 were set to Drum1, selecting STANDARD1 for Part 10
-- would automatically select STANDARD1 for Part 11 as well."
--
-- So the kit belongs to the MODE, not the Part. Holding one voice per Part
-- would let the editor show two DRUM 1 Parts on different kits -- a state
-- the hardware cannot be in, where it applies whichever was sent last to
-- both and the editor keeps claiming otherwise.
do
  local e = env({ channels = fresh_channels() })
  local voice_of, parts_sharing_voice = H.lift(
    { 'voice_of', 'parts_sharing_voice' }, e, FILE)

  -- Part 10 is DRUM 1 at power-on; make Part 11 DRUM 1 too.
  e.channels[11].values.rhythm = 1

  local followers = parts_sharing_voice(10)
  check(#followers == 2, 'two Parts share DRUM 1, got ' .. #followers)
  check(followers[1] == 10 and followers[2] == 11,
    'and they are Parts 10 and 11, got ' ..
    table.concat(followers, ', '))

  -- One store, so a write through either Part is seen by both.
  check(voice_of(10) == voice_of(11),
    'Parts on the same drum mode must share one kit')

  -- A different mode is a different kit.
  e.channels[11].values.rhythm = 2
  check(voice_of(10) ~= voice_of(11),
    'DRUM 1 and DRUM 2 are separate kits')
  check(#parts_sharing_voice(10) == 1,
    'and a Part alone on its mode follows nothing else')

  -- A melodic Part keeps its own voice, shared with no one.
  check(voice_of(1) == e.channels[1].voice,
    'a normal Part uses its own voice')
  check(voice_of(1) ~= voice_of(2),
    'and two normal Parts do not share one')

  -- Any number of Parts may be drum Parts: the limit is two KITS, not two
  -- drum Parts. A rule that forced an older Part back to None would break a
  -- setup the hardware supports.
  for i = 1, 16 do e.channels[i].values.rhythm = 1 end
  check(#parts_sharing_voice(1) == 16,
    'all sixteen Parts may share DRUM 1, got ' .. #parts_sharing_voice(1))

  H.pass('Parts sharing a drum mode share one kit (8 cases)')
end

-- changing a drum kit re-seeds that map ------------------------------------------

-- The hardware does this, so the editor has to: "When the Drum Set is changed,
-- DRUM SETUP PARAMETER values will all be initialized" (manual p.240). Keeping
-- the old kit's per-note values on screen would show state the device no
-- longer holds -- and every one of those values would then be wrong, because
-- the kits genuinely differ.
do
  local e = env({ channels = fresh_channels() })
  local _, drum_note, drum_mode_of = H.lift(
    { 'drum_kit_of', 'drum_note', 'drum_mode_of' }, e, FILE)

  -- Part 10 is DRUM 1 at power-on, and the fixture's kits are program
  -- change 0. Touch two notes so the map has state to lose.
  check(drum_mode_of(10) == 1, 'Part 10 is on DRUM 1')
  drum_note(1, 36).level = 7
  drum_note(1, 38).reverb = 9
  check(next(e.drum_maps[1].notes) ~= nil, 'the map now holds notes')

  -- Simulate what select_voice does on a kit change: the notes are dropped
  -- so the next look re-seeds them from the new kit.
  e.drum_kits[1].pc = 25          -- TR-808
  e.drum_maps[1].notes = {}

  local after = drum_note(1, 36)
  check(after.level ~= 7, 'the old kit\'s edit must not survive the change')
  local want = D.seed_values(36, 25, 4)
  for _, p in ipairs(D.PARAMS) do
    check(after[p.id] == want[p.id],
      ('after a kit change %s must seed from the new kit: %s vs %s')
        :format(p.id, tostring(after[p.id]), tostring(want[p.id])))
  end

  -- And the two kits really do differ on that note, or this proves nothing.
  local std = D.seed_values(36, 0, 4)
  local differs = false
  for _, p in ipairs(D.PARAMS) do
    if std[p.id] ~= want[p.id] then differs = true end
  end
  check(differs, 'STANDARD 1 and TR-808 must differ on note 36')
  H.pass('a kit change re-seeds its map from the new kit (14 cases)')
end

-- Driven through the real UI: clicking a kit in a drum Part's voice picker
-- drops that map's notes and its pending edit, and leaves the other map
-- alone.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32,
                     note_chan = 9, selected_tab = 'Overview',
                     keep_open = true,
                     open_popup = 'voice-10',
                     click_voice = 'TR-808##0-4-25' })
  check(not st.error, 'changing a drum kit must not throw: ' .. tostring(st.error))
  -- The kit change is a voice selection like any other, so it still sends
  -- its three messages.
  for _ = 1, 4 do
    st.now = st.now + 1
    st.deferred()
  end
  check(#st.sent >= 3, 'a kit change still sends its voice messages, got ' .. #st.sent)
end
H.pass('a drum kit change goes through the voice path (2 cases)')

-- Closing twice must not return to PAGER twice. The guard is what makes the
-- footer button and the window close button safe to both fire.
do
  local st = drive()
  local drew = st.begins
  st.deferred()
  check(st.closes == 1,
    'a frame after close must not call on_close again, got ' .. st.closes)
  check(st.begins == drew,
    'a frame after close must not draw into the released context')
  H.pass('one close per visit, however many routes fire (2 cases)')
end

-- A second visit restores the first one's values passively, and says so.
do
  local st1, tool1 = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32, keep_open = true })
  -- (the module is reloaded per drive, so the same ext table is the only
  -- thing that carries between the two visits)
  st1.open = false
  st1.deferred()

  local st2 = drive({ ext = st1.ext, editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32 })
  local said = table.concat(st2.texts, ' | ')
  check(said:find('Restored', 1, true),
    'a restore must be announced, got ' .. said)
  check(#st2.sent == 0, 'a restore must send nothing to the hardware')
  H.pass('a reopened tool restores passively and announces it (2 cases)')
end

-- A project-tab change while the window is open ------------------------------------

-- The values on screen belong to the OLD project until the switch is noticed,
-- so both the save and the load have to name their project explicitly. A key
-- that resolved the project itself would file the old values under the new
-- key and read that same record straight back -- which looks exactly like a
-- restore that changed nothing.
do
  local st = drive({ editor = 'ED', take = 'TAKE', track = 'TRK', hwout = 32, keep_open = true })
  check(st.closes == 0, 'the window is still open')

  st.project = 'proj-B'
  st.deferred()

  local said = table.concat(st.texts, ' | ')
  check(said:find('Restored', 1, true),
    'a project switch must announce the restore, got ' .. said)
  check(#st.sent == 0, 'a project switch must not send to the hardware')
  check(not st.error, 'the switch frame must not throw: ' .. tostring(st.error))

  st.open = false
  st.deferred()
  check(st.closes == 1, 'and the tool still closes once')

  -- Two projects, two records, both under this tool's own key.
  local keys = 0
  for k in pairs(st.ext) do
    if k:find('part_editor', 1, true) then keys = keys + 1 end
  end
  check(keys == 2, 'each project must keep its own record, got ' .. keys)
  H.pass('a project switch saves the old project and loads the new one (6 cases)')
end
