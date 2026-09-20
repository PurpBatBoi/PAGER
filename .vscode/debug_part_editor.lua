-- Local development launcher for attaching VS Code's LuaPanda debugger to the
-- Part Editor, opened directly rather than through PAGER.
--
-- Use this one when the bug is inside part_editor.lua and you want the window
-- up in one keystroke. Use debug_pager.lua instead when the launcher handoff
-- itself matters -- breakpoints in the tools hit either way, because PAGER
-- loadfile()s them into the same Lua state.
--
-- The Part Editor needs a MIDI editor open to do anything: the active take
-- and the piano-roll channel both come from it. With none open the panel is
-- deliberately inert, which is a valid thing to debug but not the interesting
-- one.

local action_path = ({ reaper.get_action_context() })[2]
action_path = action_path and action_path:gsub('\\', '/')
local workspace = action_path and action_path:match('^(.*)/%.vscode/[^/]+%.lua$')
assert(workspace, 'Run this launcher from PAGER/.vscode')

local home = os.getenv('USERPROFILE') or os.getenv('HOME')
assert(home, 'Neither USERPROFILE nor HOME is available')
local extensions_root = home:gsub('\\', '/') .. '/.vscode/extensions'

local function parse_version(name)
  local version = name:match('^antoinebalaine%.reascript%-docs%-(%d[%d%.]*)$')
  if not version then return nil end

  local parts = {}
  for part in version:gmatch('%d+') do
    parts[#parts + 1] = tonumber(part)
  end
  return parts
end

local function is_newer(candidate, current)
  if not current then return true end
  local count = math.max(#candidate, #current)
  for index = 1, count do
    local left, right = candidate[index] or 0, current[index] or 0
    if left ~= right then return left > right end
  end
  return false
end

local extension_name, extension_version
local index = 0
while true do
  local name = reaper.EnumerateSubdirectories(extensions_root, index)
  if not name then break end

  local version = parse_version(name)
  if version and is_newer(version, extension_version) then
    extension_name, extension_version = name, version
  end
  index = index + 1
end

assert(extension_name,
  'VS Code extension AntoineBalaine.reascript-docs is not installed')

local debugger_loader = extensions_root .. '/' .. extension_name
  .. '/debugger/LoadDebug.lua'
assert(reaper.file_exists(debugger_loader),
  'ReaScript debugger loader not found: ' .. debugger_loader)

-- The real editor derives its module directory from the action context. This
-- launcher is the registered action, so seed the real source paths first.
package.path = workspace .. '/editor/?.lua;'
  .. workspace .. '/lib/?.lua;' .. package.path

local VSDEBUG = dofile(debugger_loader)
dofile(workspace .. '/editor/part_editor.lua')

