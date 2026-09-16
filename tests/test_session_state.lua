-- session_state.lua: what survives a close, what does not, and what happens
-- when what comes back is not what went out.
--
-- The module is the only thing standing between a tool's plain Lua table and
-- REAPER's ExtState, so the four properties the plan names are checked here
-- against a fake reaper rather than in REAPER: per-project isolation,
-- non-persistent writes, schema-version mismatch, and malformed JSON.
--
-- Every failure mode has the same answer -- load() returns nil and the tool
-- starts from defaults -- which is exactly why each one is checked separately.
-- A single "returns nil on bad input" test would pass even if, say, a version
-- mismatch were silently accepted and the *state* happened to be nil.
--   lua tests/test_session_state.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local check = H.check
local SessionState = require 'session_state'
local json = require 'json'

-- A fake ExtState: one flat store keyed exactly as REAPER keys it, plus a log
-- of the persist flag every write passed, which is the only way to observe
-- that state is not being written to disk.
local function fake_reaper(project)
  local R = {
    store = {},
    writes = {},       -- { section, key, value, persist } per SetExtState
    project = project or 'proj-A',
  }
  function R.GetExtState(section, key)
    return R.store[section .. '\0' .. key] or ''
  end
  function R.SetExtState(section, key, value, persist)
    R.store[section .. '\0' .. key] = value
    R.writes[#R.writes + 1] =
      { section = section, key = key, value = value, persist = persist }
  end
  -- EnumProjects(-1) is the active project. The fake returns a plain string
  -- where REAPER returns userdata; project_key tostrings either one.
  function R.EnumProjects(index)
    check(index == -1, 'the active project is asked for with EnumProjects(-1)')
    return R.project
  end
  return R
end

-- A round trip carries a plain table back unchanged.
do
  local R = fake_reaper()
  local ss = SessionState.new({ reaper = R })

  local ok = ss:save('effects_editor', {
    efx_type = 7,
    cfg = { midi_tick_gap = 3, label_events = false },
    masters = { 127, 0, 0, 4400 },
    active_tab = 'Insertion Effects',
  })
  check(ok, 'a plain table saves')

  local back = ss:load('effects_editor')
  check(back, 'what was saved comes back')
  check(back.efx_type == 7, 'a number survives the round trip')
  check(back.cfg.label_events == false,
    'false survives -- it must not be confused with absent')
  check(back.masters[4] == 4400, 'a nested list survives')
  check(back.active_tab == 'Insertion Effects', 'a string survives')
end

-- Nothing is written for the next REAPER process. persist=false is what makes
-- the state last for this session only, which is the behaviour the plan asks
-- for (item 2) -- a true here would put tool settings in reaper-extstate.ini
-- and quietly make them permanent.
do
  local R = fake_reaper()
  local ss = SessionState.new({ reaper = R })
  ss:save('effects_editor', { a = 1 })
  check(#R.writes == 1, 'one save is one write')
  check(R.writes[1].persist == false,
    'state must be written with persist=false -- it must not outlive REAPER')
  check(R.writes[1].section == SessionState.SECTION,
    'every tool shares one ExtState section')
end

-- Per-project isolation (plan item 5). Two project tabs are two records; one
-- does not read or overwrite the other, and switching back finds the original.
do
  local R = fake_reaper('proj-A')
  local ss = SessionState.new({ reaper = R })

  ss:save('effects_editor', { efx_type = 3 })

  R.project = 'proj-B'
  check(ss:load('effects_editor') == nil,
    'a second project tab starts with no state of its own')
  ss:save('effects_editor', { efx_type = 9 })
  check(ss:load('effects_editor').efx_type == 9, 'the second project keeps its own')

  R.project = 'proj-A'
  check(ss:load('effects_editor').efx_type == 3,
    'the first project is untouched by the second')

  -- Two projects, two distinct keys, so neither can clobber the other.
  local keys = {}
  for _, w in ipairs(R.writes) do keys[w.key] = true end
  local n = 0
  for _ in pairs(keys) do n = n + 1 end
  check(n == 2, 'two projects produce two keys, got ' .. n)
end

-- A named project overrides what REAPER currently reports. This is what makes
-- a live project-tab switch correct: the tool notices one frame after the
-- change, so it must be able to write the values it still holds under the
-- project they came from, not under the one REAPER has already moved to.
do
  local R = fake_reaper('proj-A')
  local ss = SessionState.new({ reaper = R })

  ss:save('effects_editor', { efx_type = 3 })

  -- REAPER moves on; the tool has not noticed yet.
  R.project = 'proj-B'

  -- Saving the values it still holds, under the project they belong to.
  ss:save('effects_editor', { efx_type = 7 }, 'proj-A')
  check(ss:load('effects_editor', 'proj-A').efx_type == 7,
    'an explicitly named project is the one written')
  check(ss:load('effects_editor') == nil,
    'naming a project must not write into the project REAPER now reports')

  -- And reading the new project by name, which is what the swap loads.
  ss:save('effects_editor', { efx_type = 9 }, 'proj-B')
  check(ss:load('effects_editor', 'proj-B').efx_type == 9,
    'an explicitly named project is the one read')
  check(ss:load('effects_editor', 'proj-A').efx_type == 7,
    'the other project is untouched')

  -- Omitting it still means "whatever is current now".
  check(ss:load('effects_editor').efx_type == 9,
    'omitting the project falls back to the current one')
end

-- Tools are separated as well as projects: the Effects Editor's state must
-- never be handed to MIDI Export, whose fields are entirely different.
do
  local R = fake_reaper()
  local ss = SessionState.new({ reaper = R })
  ss:save('effects_editor', { efx_type = 4 })
  check(ss:load('midi_export') == nil, 'one tool cannot read another tool state')
end

-- Absent state. A first-ever visit has no record, and load must say so rather
-- than returning an empty table the tool would treat as a real restore.
do
  local R = fake_reaper()
  local ss = SessionState.new({ reaper = R })
  check(ss:load('effects_editor') == nil, 'no record reads as nil')
end

-- Malformed JSON falls back to defaults instead of raising. The decode runs
-- inside pcall; without it a truncated record would throw out of the tool's
-- start() and leave no window at all.
do
  local R = fake_reaper()
  local ss = SessionState.new({ reaper = R })
  local key = SessionState.SECTION .. '\0' .. ss:key('effects_editor')

  for _, bad in ipairs({
    '{"version":1,"state":{',      -- truncated
    'not json at all',
    '[1,2,3]',                     -- valid JSON, wrong shape
    '{"version":1}',               -- no state payload
    '{"version":1,"state":42}',    -- state is not a table
    '{"state":{"a":1}}',           -- no version
  }) do
    R.store[key] = bad
    local okcall, result = pcall(ss.load, ss, 'effects_editor')
    check(okcall, 'malformed state must not raise: ' .. bad)
    check(result == nil, 'malformed state must read as nil: ' .. bad)
  end
end

-- A record written by another schema version is discarded, not guessed at.
-- Half-understanding an old record is worse than starting clean, because the
-- user cannot see which fields came back wrong.
do
  local R = fake_reaper()
  local ss = SessionState.new({ reaper = R })
  local key = SessionState.SECTION .. '\0' .. ss:key('effects_editor')

  R.store[key] = json.encode({ version = SessionState.VERSION + 1,
                               state = { efx_type = 5 } })
  check(ss:load('effects_editor') == nil, 'a newer schema version is discarded')

  R.store[key] = json.encode({ version = SessionState.VERSION - 1,
                               state = { efx_type = 5 } })
  check(ss:load('effects_editor') == nil, 'an older schema version is discarded')

  -- The current version is the one that loads, which is what makes the two
  -- checks above meaningful rather than "load always returns nil".
  R.store[key] = json.encode({ version = SessionState.VERSION,
                               state = { efx_type = 5 } })
  check(ss:load('effects_editor').efx_type == 5, 'the current version loads')
end

-- Saving something unserializable reports rather than throwing. A tool must
-- still close and return to PAGER even if its state cannot be written.
do
  local R = fake_reaper()
  local ss = SessionState.new({ reaper = R })

  local ok = ss:save('effects_editor', 'not a table')
  check(ok == false, 'a non-table is refused')

  local okcall, wrote = pcall(ss.save, ss, 'effects_editor', { f = function() end })
  check(okcall, 'an unserializable value must not raise out of save')
  check(wrote == false, 'an unserializable value reports failure')
end

-- clear removes a record without leaving a decodable husk behind.
do
  local R = fake_reaper()
  local ss = SessionState.new({ reaper = R })
  ss:save('effects_editor', { efx_type = 2 })
  ss:clear('effects_editor')
  check(ss:load('effects_editor') == nil, 'a cleared record reads as nil')
  check(R.writes[#R.writes].persist == false, 'clearing is also non-persistent')
end

-- A REAPER that cannot answer EnumProjects still yields a usable key: state is
-- then shared across tabs rather than lost or raising on every save.
do
  local R = fake_reaper()
  R.EnumProjects = function() error('no such function') end
  local ss = SessionState.new({ reaper = R })
  check(ss:project_key() == 'default', 'an unavailable project falls back')
  check(ss:save('effects_editor', { a = 1 }), 'saving still works')
  check(ss:load('effects_editor').a == 1, 'loading still works')
end

H.pass('session state: round trip, persist=false, per-project and per-tool ' ..
       'isolation, explicit project override, malformed JSON, schema ' ..
       'mismatch, clear (11 groups)')
