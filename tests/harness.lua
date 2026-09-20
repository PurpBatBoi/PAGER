-- Shared test harness: lifting functions out of the editor, and the fake
-- REAPER pieces the lifted code reaches for.
--
-- Every test in this folder compiles real functions out of effects_editor.lua
-- against a small environment rather than copying them, so a change to the
-- editor runs here instead of a stale duplicate. Three things were repeated
-- in every file before this module existed: reading the source, matching one
-- function body out of it, and building a take/MIDI fake to observe what the
-- lifted code did.
--
-- The fakes are deliberately mode-agnostic. The refactor removes cfg.mode and
-- the sending()/previewing() split, so a harness that bakes 'item'/'live'
-- into its shape would have to be rewritten with the production code. Instead
-- a test declares the collaborators it wants (sending, send_live, ...) and
-- everything else comes from here.

local H = {}

-- Where the editor sources live, relative to the running test file.
local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
H.DIR = dir
H.EDITOR = dir .. '/../editor/'

-- source access -------------------------------------------------------------

local src_cache = {}

-- Read one editor file, cached: several lifts per test file are normal and
-- effects_editor.lua is 73 KB.
function H.source(file)
  file = file or 'effects_editor.lua'
  if src_cache[file] then return src_cache[file] end
  local path = H.EDITOR .. file
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local text = f:read('a')
  f:close()
  src_cache[file] = text
  return text
end

-- Match one top-level `local function name(...)` body out of the source. The
-- pattern anchors on a newline and the closing `\nend`, which is what makes
-- it pick the whole function rather than a nested one.
function H.body(name, file)
  local src = H.source(file)
  local pat = '\n(local function ' .. name:gsub('%p', '%%%0') .. '%b()'
  local body = src:match(pat .. '.-\nend)\n')
  assert(body, name .. ' not found in ' .. (file or 'effects_editor.lua') ..
                ' -- was it renamed? this test must follow it')
  return body
end

-- Match a top-level `local NAME = { ... }` table literal.
function H.table_body(name, file)
  local src = H.source(file)
  local body = src:match('\n(local ' .. name .. ' = {.-\n})\n')
  assert(body, name .. ' not found in ' .. (file or 'effects_editor.lua') ..
                ' -- was it renamed or moved?')
  return body
end

-- Lift one or more named functions, compiled together against `env` so they
-- can call each other. Returns them in the order named.
--
-- env is the whole world the lifted code sees: anything it reaches for that
-- is not there raises a nil-index error here rather than passing quietly,
-- which is the point -- a new dependency on editor state shows up as a test
-- failure the moment it appears.
function H.lift(names, env, file)
  local parts, rets = {}, {}
  for i, name in ipairs(names) do
    parts[i] = H.body(name, file)
    rets[i] = name
  end
  local chunk = assert(load(
    table.concat(parts, '\n') .. '\nreturn ' .. table.concat(rets, ', '),
    names[1], 't', env))
  return chunk()
end

-- fake REAPER ---------------------------------------------------------------

-- The MIDI event lane, as the editor sees it through the reaper.MIDI_* calls
-- it uses. Events are kept in a plain array of { ppq, typ, payload }; the
-- editor addresses them by index, so deletion has to preserve the indices of
-- everything before it, exactly as REAPER's own API does.
--
-- Only the calls the editor actually makes are implemented. Anything else is
-- absent on purpose.
function H.take(opts)
  opts = opts or {}
  local t = {
    events = {},          -- { ppq, typ, payload } in insertion order
    ccs = {},             -- { ppq, chanmsg, chan, msg2, msg3 } in insertion order
    log = {},             -- every observable call, in order
    sorted = 0,           -- MIDI_Sort count
    undo = {},            -- Undo_EndBlock descriptions
    cursor = opts.cursor or 1000,
    ppq_per_qn = opts.ppq_per_qn or 960,
    hwout = opts.hwout == nil and 0 or opts.hwout,
    sent = {},            -- framed messages handed to the hardware
  }

  function t:count() return #self.events end

  -- Events at one tick, in index order.
  function t:at(ppq)
    local out = {}
    for _, e in ipairs(self.events) do
      if e.ppq == ppq then out[#out + 1] = e end
    end
    return out
  end

  -- SysEx payloads in tick order, which is what a run's layout means.
  function t:run()
    local out = {}
    for _, e in ipairs(self.events) do
      if e.typ == -1 then out[#out + 1] = { ppq = e.ppq, payload = e.payload } end
    end
    table.sort(out, function(a, b) return a.ppq < b.ppq end)
    return out
  end

  -- Text-lane labels, in tick order.
  function t:labels()
    local out = {}
    for _, e in ipairs(self.events) do
      if e.typ == 1 then out[#out + 1] = { ppq = e.ppq, text = e.payload } end
    end
    table.sort(out, function(a, b) return a.ppq < b.ppq end)
    return out
  end

  -- CC events as short readable strings, in insertion order. The Part Editor
  -- writes into this lane, and a failure is only legible if it prints as MIDI.
  function t:cc_list()
    local out = {}
    for _, c in ipairs(self.ccs) do
      out[#out + 1] = ('@%d ch%d #%d=%d')
        :format(c.ppq, c.chan, c.msg2, c.msg3)
    end
    return out
  end

  -- CC events at one tick, in index order.
  function t:cc_at(ppq)
    local out = {}
    for _, c in ipairs(self.ccs) do
      if c.ppq == ppq then out[#out + 1] = c end
    end
    return out
  end

  -- Seed a CC event directly, as though something else had written it. Used
  -- to prove that replacement leaves unrelated events alone.
  function t:add_cc(ppq, chan, msg2, msg3, chanmsg)
    self.ccs[#self.ccs + 1] = { ppq = ppq, chanmsg = chanmsg or 0xB0,
                                chan = chan, msg2 = msg2, msg3 = msg3 }
    return self
  end

  -- Seed a text/sysex event directly, for the same reason.
  function t:add_evt(ppq, typ, payload)
    self.events[#self.events + 1] = { ppq = ppq, typ = typ, payload = payload }
    return self
  end

  -- The distinct ticks a run occupies, ascending.
  function t:ticks()
    local seen, out = {}, {}
    for _, e in ipairs(self.events) do
      if e.typ == -1 and not seen[e.ppq] then
        seen[e.ppq] = true
        out[#out + 1] = e.ppq
      end
    end
    table.sort(out)
    return out
  end

  return t
end

-- A reaper table wired to one fake take. `extra` overrides or adds entries,
-- so a test can watch one call without restating the rest.
function H.reaper(take, extra)
  local R
  R = {
    Undo_BeginBlock = function() take.log[#take.log + 1] = { 'undo_begin' } end,
    Undo_EndBlock = function(desc)
      take.undo[#take.undo + 1] = desc
      take.log[#take.log + 1] = { 'undo_end', desc }
    end,
    MIDI_Sort = function()
      take.sorted = take.sorted + 1
      take.log[#take.log + 1] = { 'sort' }
    end,
    MIDI_InsertTextSysexEvt = function(_, _, _, ppq, typ, payload)
      take.events[#take.events + 1] = { ppq = ppq, typ = typ, payload = payload }
      take.log[#take.log + 1] = { 'insert', ppq, typ, payload }
    end,
    -- REAPER indexes text/sysex events from 0; the array is 1-based, so every
    -- index crossing this boundary is converted exactly once. Getting this
    -- wrong would make delete_at skip an event and still look plausible.
    MIDI_SetTextSysexEvt = function(_, idx, _, _, ppq, typ, payload)
      local e = take.events[idx + 1]
      assert(e, 'MIDI_SetTextSysexEvt on index ' .. tostring(idx) .. ' which does not exist')
      e.ppq, e.typ, e.payload = ppq, typ, payload
      take.log[#take.log + 1] = { 'set', idx, ppq, typ, payload }
    end,
    MIDI_DeleteTextSysexEvt = function(_, idx)
      assert(take.events[idx + 1], 'MIDI_DeleteTextSysexEvt on a missing index')
      table.remove(take.events, idx + 1)
      take.log[#take.log + 1] = { 'delete', idx }
    end,
    MIDI_CountEvts = function()
      return true, 0, #take.ccs, #take.events
    end,
    -- The CC lane. REAPER indexes it from 0 and the array is 1-based, so
    -- every index crossing this boundary is converted exactly once -- the
    -- same rule the text/sysex calls above follow.
    MIDI_GetCC = function(_, idx)
      local c = take.ccs[idx + 1]
      if not c then return false end
      return true, false, false, c.ppq, c.chanmsg, c.chan, c.msg2, c.msg3
    end,
    MIDI_InsertCC = function(_, _, _, ppq, chanmsg, chan, msg2, msg3)
      take.ccs[#take.ccs + 1] = { ppq = ppq, chanmsg = chanmsg, chan = chan,
                                  msg2 = msg2, msg3 = msg3 }
      take.log[#take.log + 1] = { 'insert_cc', ppq, chan, msg2, msg3 }
      return true
    end,
    MIDI_DeleteCC = function(_, idx)
      assert(take.ccs[idx + 1], 'MIDI_DeleteCC on a missing index')
      table.remove(take.ccs, idx + 1)
      take.log[#take.log + 1] = { 'delete_cc', idx }
      return true
    end,
    -- Quarter notes to ticks. The Part Editor derives its run spacing from
    -- the distance between two of them, so this has to be linear and exact.
    MIDI_GetPPQPosFromProjQN = function(_, qn) return qn * take.ppq_per_qn end,
    MIDI_GetTextSysexEvt = function(_, idx)
      local e = take.events[idx + 1]
      if not e then return false end
      return true, false, false, e.ppq, e.typ, e.payload
    end,
    MIDI_GetPPQPosFromProjTime = function() return take.cursor end,
    GetCursorPosition = function() return 0 end,
    GetMediaItemTake_Track = function() return 'TRACK' end,
    GetMediaTrackInfo_Value = function() return take.hwout end,
    SendMIDIMessageToHardware = function(dev, msg)
      take.sent[#take.sent + 1] = { dev = dev, msg = msg }
      take.log[#take.log + 1] = { 'send', dev, msg }
    end,
    time_precise = function() return 0 end,
  }
  for k, v in pairs(extra or {}) do R[k] = v end
  return R
end

-- assertions ----------------------------------------------------------------

function H.check(cond, msg)
  if not cond then error(msg, 2) end
end

-- Ticks must be evenly spaced by `gap` from `base`, and no two events may
-- share a tick -- the hardware drops all but one SysEx message sent at the
-- same instant, so a collapsed run looks right in the item and sounds wrong.
function H.check_spacing(ticks, base, gap, what)
  what = what or 'run'
  for i, ppq in ipairs(ticks) do
    local want = base + (i - 1) * gap
    H.check(ppq == want,
      ('%s: event %d at ppq %d, expected %d'):format(what, i, ppq, want))
  end
  local seen = {}
  for _, ppq in ipairs(ticks) do
    H.check(not seen[ppq], ('%s: two events share ppq %d'):format(what, ppq))
    seen[ppq] = true
  end
end

-- Report a passing file in one consistent line.
function H.pass(text) print('ok: ' .. text) end

return H
