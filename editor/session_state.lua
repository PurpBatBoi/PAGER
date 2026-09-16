-- PAGER - per-session, per-project tool state.
--
-- Owns the one job of getting a tool's plain Lua table out to REAPER and back
-- again between windows: JSON encoding, the ExtState key, the per-project
-- split, the schema version, and what happens when what comes back is not
-- what went out.
--
-- Lifetime is deliberate. SetExtState with persist=false keeps the value in
-- REAPER's memory for this process only, so state survives closing a tool,
-- returning to PAGER and running the PAGER action again, and is gone when
-- REAPER closes. Nothing is written into the project file.
--
-- Scope is per project tab. EnumProjects(-1) returns the active project, and
-- its pointer (rendered as a string) keys the record, so two open tabs keep
-- separate values and switching tabs selects a different record rather than
-- carrying one project's settings into another.
--
-- What this module does NOT do: validate a tool's fields. It guarantees only
-- that load() returns either a table that round-tripped through JSON at the
-- current schema version, or nil. Ranges, types and enum membership are the
-- tool's own business, because only the tool knows them -- see the validating
-- restore in effects_editor.lua.
--
-- Dependencies are injected through new(deps) so the module can be tested
-- outside REAPER; in REAPER the caller passes the real reaper table.

local json = require 'json'

local M = {}
M.__index = M

-- The ExtState section every PAGER tool shares. Keys inside it are
-- "<tool>:<project>", so one section holds every tool for every open tab.
M.SECTION = 'PAGER_session'

-- Bumped when the saved shape changes incompatibly. A record carrying any
-- other version is discarded rather than guessed at -- a half-understood
-- restore is worse than a clean default, because the user cannot see which
-- fields came back wrong.
M.VERSION = 1

-- deps.reaper : the reaper table (GetExtState, SetExtState, EnumProjects)
function M.new(deps)
  deps = deps or {}
  return setmetatable({ reaper = deps.reaper or reaper }, M)
end

-- The active project, as a stable string. EnumProjects(-1) is the documented
-- way to ask for the current one; its userdata pointer formats to a value
-- that stays the same while the tab is open, which is all the key needs.
-- A REAPER that cannot answer still gets a usable key, so state is merely
-- shared across tabs rather than lost.
function M:project_key()
  local ok, proj = pcall(self.reaper.EnumProjects, -1)
  if not ok or proj == nil then return 'default' end
  return tostring(proj)
end

-- The record key for one tool in one project.
--
-- `project` is passed explicitly rather than read here, because the caller and
-- REAPER can disagree about which project is current at exactly the moment
-- that matters. When the user switches project tabs, the tool notices one
-- frame later -- REAPER already reports the NEW project while the values still
-- in the editor belong to the OLD one. A key that asked project_key() itself
-- would then file the old project's values under the new project's key,
-- overwriting the state the tool is about to load.
--
-- Omitting it means "the project that is current right now", which is correct
-- for open and close, where the two agree.
function M:key(tool, project)
  return tool .. ':' .. (project or self:project_key())
end

-- Save one tool's state. `state` is a plain table; `project` names the record
-- to write, defaulting to the one current now.
-- Returns true when it was written, or false plus a message -- a tool that
-- cannot be serialized must not take the window down with it, so the caller
-- is told and carries on closing.
function M:save(tool, state, project)
  if type(state) ~= 'table' then
    return false, 'state must be a table'
  end
  local record = { version = M.VERSION, state = state }
  local ok, text = pcall(json.encode, record)
  if not ok then return false, tostring(text) end
  self.reaper.SetExtState(M.SECTION, self:key(tool, project), text, false)
  return true
end

-- Load one tool's state, or nil when there is none. `project` names the record
-- to read, defaulting to the one current now.
--
-- Every failure returns nil, which the caller reads as "start from defaults":
-- no record, malformed JSON, a record that is not an object, a version that
-- is not ours, or a payload that is not a table. Malformed state is dropped
-- silently on purpose. It can only come from a previous run of this same
-- process, so there is nothing the user could act on, and a startup error
-- popup in its place would be noise in front of a window that is about to
-- open correctly anyway.
function M:load(tool, project)
  local text = self.reaper.GetExtState(M.SECTION, self:key(tool, project))
  if type(text) ~= 'string' or text == '' then return nil end

  local ok, record = pcall(json.decode, text)
  if not ok or type(record) ~= 'table' then return nil end
  if record.version ~= M.VERSION then return nil end
  if type(record.state) ~= 'table' then return nil end
  return record.state
end

-- Drop one tool's record for the current project. Not used by the normal
-- close path -- state is meant to survive that -- but a tool that finds its
-- own state unusable can clear it rather than rewrite it every close.
function M:clear(tool, project)
  self.reaper.SetExtState(M.SECTION, self:key(tool, project), '', false)
end

return M
