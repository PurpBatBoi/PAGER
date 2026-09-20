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
local check = H.check

local FILE = 'part_editor.lua'

-- lifted logic ----------------------------------------------------------------

-- The environment the lifted functions see. Anything they reach for that is
-- absent raises here rather than passing quietly, which is the point: a new
-- dependency on editor state shows up as a failure the moment it appears.
local function env(over)
  local e = {
    P = P,
    PM = require 'part_messages',
    ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
    math = math, string = string, table = table, pcall = pcall,
    channels = {},
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

local function fresh_channels()
  local c = {}
  for i = 1, 16 do
    c[i] = { values = blank_values(), use_sysex = false, pending = nil }
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
  }
  for _, c in ipairs(CASES) do
    local got = display_value(P.BY_ID[c[1]], c[2])
    check(got == c[3],
      ('display %s %s = %s, expected %s'):format(c[1], c[2], got, c[3]))
  end
  H.pass('values display in musical units, not bytes (15 cases)')
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
  local _, _, _, cm = H.lift(
    { 'set_status', 'preview', 'set_pending', 'commit' }, e, FILE)

  -- A settled edit previews and becomes pending, in that order of effect:
  -- both must be true afterwards.
  cm('TAKE', 1, 'cutoff', 20)
  check(#queued == 1, 'a settled edit must preview')
  check(queued[1].addr == 'cutoff', 'the preview must name the logical parameter')
  check(e.channels[1].pending.id == 'cutoff', 'and must become pending')

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
  H.pass('a settled edit previews and stays pending even when the route fails (8 cases)')
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
  local capture_state, restore_state = H.lift(
    { 'capture_state', 'restore_state' }, e, FILE)

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

-- the whole tool, through a headless ImGui ------------------------------------------------

-- The same boundary test_tool_lifecycle.lua uses. Everything reports
-- "unchanged" so a frame draws the whole UI without simulating input.
local function fake_imgui(state)
  local ImGui = {}
  local function unchanged(_, _, value) return false, value end

  local passthrough = {
    SliderInt = unchanged, SliderDouble = unchanged,
    Checkbox = function(_, label, value)
      state.checkboxes[#state.checkboxes + 1] =
        { label = label, disabled = state.disable_depth > 0 }
      return false, value
    end,
    Button = function(_, label)
      state.buttons[#state.buttons + 1] =
        { label = label, disabled = state.disable_depth > 0 }
      return false
    end,
    BeginChild = function() return true end,
    Begin = function(_, title)
      state.begins = state.begins + 1
      state.title = title
      state.fonts_at_begin = state.pushed_fonts - state.popped_fonts
      state.styles_at_begin = state.pushed_colors - state.popped_colors
      -- Per-frame, not cumulative: "how many times was this group drawn"
      -- only means something within one frame, and the tool draws several.
      state.groups = {}
      state.buttons = {}
      state.checkboxes = {}
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
  end
  ImGui.EndDisabled = function()
    state.disable_depth = state.disable_depth - 1
    check(state.disable_depth >= 0, 'EndDisabled without a BeginDisabled')
  end
  ImGui.Text = function(_, text)
    state.texts[#state.texts + 1] = tostring(text)
    -- The loop catches a throwing frame and puts it on the status line, so a
    -- crash inside frame() is observable here rather than silently swallowed.
    if tostring(text):find('ERROR') then state.error = tostring(text) end
  end
  ImGui.SeparatorText = function(_, text)
    state.groups[#state.groups + 1] = tostring(text)
  end

  ImGui.CalcTextSize = function(_, text) return #(text or '') * 7, 14 end
  ImGui.GetFrameHeight = function() return 21 end
  ImGui.GetFrameHeightWithSpacing = function() return 25 end
  ImGui.GetFontSize = function() return 14 end
  ImGui.GetContentRegionAvail = function() return 400, 300 end
  ImGui.GetCursorPos = function() return 0, 0 end
  ImGui.GetStyleVar = function() return 4, 4 end
  ImGui.IsItemDeactivatedAfterEdit = function() return false end
  ImGui.IsItemHovered = function() return false end
  ImGui.IsMouseDoubleClicked = function() return false end
  ImGui.IsMouseDown = function() return false end

  setmetatable(ImGui, {
    __index = function(_, key)
      local value
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
    GetMediaItemTake_Track = function() return nil end,
    GetMediaTrackInfo_Value = function() return -1 end,
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
    contexts = 0, begins = 0,
    fonts_created = 0, fonts_attached = 0,
    pushed_fonts = 0, popped_fonts = 0,
    pushed_colors = 0, popped_colors = 0,
    pushed_vars = 0, popped_vars = 0,
    disable_depth = 0, disabled_ever = false,
    buttons = {}, texts = {}, groups = {}, checkboxes = {},
    sent = {}, persists = {},
    ext = opts.ext or {},
    project = opts.project or 'proj-A',
    visible = true, open = true,
    editor = opts.editor, take = opts.take,
    note_chan = opts.note_chan,
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
  check(said:find('No active MIDI editor', 1, true),
    'and must explain the required context, got ' .. said)

  -- The controls are drawn, not hidden, so the user can see what the tool
  -- offers. That is what makes the nil Part reachable: every row still needs
  -- a channel to read a value from, and there is no active one. Drawing them
  -- at all is the regression this asserts.
  check(#st.groups >= #P.GROUPS,
    'every group must still be drawn while disabled, got ' .. #st.groups)

  -- The panel is two columns, so every group has to appear in exactly one of
  -- them. A group added to part_params.lua but not to COLUMNS would simply
  -- never be drawn, and nothing else would notice.
  local drew = {}
  for _, g in ipairs(st.groups) do drew[g] = (drew[g] or 0) + 1 end
  for _, g in ipairs(P.GROUPS) do
    check(drew[g] == 1,
      ('group %s must be drawn exactly once, got %s'):format(g, tostring(drew[g])))
  end

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
  local st = drive({ editor = 'ED', take = 'TAKE', note_chan = 9 })

  local drawn = table.concat(st.groups, ' | ')
  for _, group in ipairs(P.GROUPS) do
    check(st.groups[1] and drawn:find(group, 1, true),
      'the panel must draw the ' .. group .. ' group, got ' .. drawn)
  end

  local said = table.concat(st.texts, ' | ')
  check(said:find('Channel 10', 1, true),
    'the header must name the Part, got ' .. said)

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
  local st1, tool1 = drive({ editor = 'ED', take = 'TAKE', keep_open = true })
  -- (the module is reloaded per drive, so the same ext table is the only
  -- thing that carries between the two visits)
  st1.open = false
  st1.deferred()

  local st2 = drive({ ext = st1.ext, editor = 'ED', take = 'TAKE' })
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
  local st = drive({ editor = 'ED', take = 'TAKE', keep_open = true })
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
