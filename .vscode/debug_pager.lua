-- Local development launcher for attaching VS Code's LuaPanda debugger to the
-- whole PAGER suite: the launcher and every tool it opens.
--
-- debug_effects_editor.lua loads one tool directly, which is the right thing
-- when the bug is inside that editor. This one loads pager.lua instead, so
-- the handoff itself -- launcher closes, tool starts, tool closes, launcher
-- reopens -- runs under the debugger. Breakpoints in the tools still hit:
-- PAGER loadfile()s them into the same Lua state this file is running in.

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

-- The extension directory carries its version, so it changes on every VS Code
-- update. Discover the newest rather than hard-coding one.
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

-- PAGER derives its module directory from the action context, and this
-- launcher is the registered action -- so the context points at .vscode/
-- rather than editor/. Seed the real source paths first.
package.path = workspace .. '/editor/?.lua;'
  .. workspace .. '/lib/?.lua;' .. package.path

local VSDEBUG = dofile(debugger_loader)
dofile(workspace .. '/editor/pager.lua')
