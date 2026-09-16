-- Regression: theme.font must never hand back a font from a dead context.
--
-- Found in REAPER, not here: close a tool, let PAGER reopen, and the next
-- frame died with
--
--   theme.lua:107: ImGui_PushFont: expected a valid ImGui_Font*, got 0x34cdb380
--
-- The cache is keyed on the context and the keys are weak, which looks
-- sufficient and is not. REAPER reuses the address of a released context for
-- the next one it creates, and the old entry survives until a GC cycle that
-- may not have run in between -- so the lookup hits on a *new* context and
-- returns the font attached to the destroyed one.
--
-- Identity cannot distinguish those two cases, which is the whole difficulty:
-- the stale key and the live key are equal. Only ValidatePtr can tell them
-- apart, so the cache revalidates rather than trusting a hit.
--
--   lua tests/test_theme_font.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
package.path = dir .. '/?.lua;' .. dir .. '/../editor/?.lua;' ..
               dir .. '/../lib/?.lua;' .. package.path

local H = require 'harness'
local check = H.check

-- An ImGui that models handle lifetime: a font belongs to the context that
-- was current when it was created, and stops being valid when that context
-- is released. Fonts are tables so each one is distinguishable by identity.
local function fake_imgui()
  local api = { created = 0, attached = 0, pushed = {} }
  -- font -> the context generation it is attached to. A generation is one
  -- real context: an address can host several over a session, one per tool
  -- that opens there, and a font belongs to exactly one of them.
  local live = {}
  local generation = {}  -- address -> the generation currently occupying it
  local next_generation = 0

  -- An address hosts a generation; the first lookup creates it.
  local function current(address)
    if not generation[address] then
      next_generation = next_generation + 1
      generation[address] = next_generation
    end
    return generation[address]
  end

  function api.CreateFont()
    api.created = api.created + 1
    return { id = api.created }
  end

  function api.Attach(address, font)
    api.attached = api.attached + 1
    live[font] = current(address)
  end

  -- The real check: a font is valid while the exact context generation it was
  -- attached to still occupies its address.
  function api.ValidatePtr(font, kind)
    check(kind == 'ImGui_Font*',
      'the font cache must validate against ImGui_Font*, got ' .. tostring(kind))
    local owner = live[font]
    if owner == nil then return false end
    for _, gen in pairs(generation) do
      if gen == owner then return true end
    end
    return false
  end

  -- What REAPER does on close, and the reason this bug exists: the context is
  -- destroyed and its address handed straight back to the next one. The
  -- address is unchanged; the generation behind it is not, so every font
  -- attached to the old generation is now dead.
  function api.release(address)
    next_generation = next_generation + 1
    generation[address] = next_generation
  end

  function api.PushFont(_, font)
    check(api.ValidatePtr(font, 'ImGui_Font*'),
      'PushFont was given a font from a released context')
    api.pushed[#api.pushed + 1] = font
  end

  function api.PopFont() end
  function api.PushStyleColor() end
  function api.PopStyleColor() end
  function api.PushStyleVar() end
  function api.PopStyleVar() end

  return api
end

-- One context, many frames: the font is made once and reused.
do
  package.loaded.theme = nil
  local theme = require 'theme'
  local ImGui = fake_imgui()
  local ctx = 'ctx'

  local first = theme.font(ctx, ImGui)
  for _ = 1, 5 do
    check(theme.font(ctx, ImGui) == first,
      'a live context keeps its font across frames')
  end
  check(ImGui.created == 1,
    'one font per context, got ' .. ImGui.created)
end

-- The reported crash: a context is released, the next one reuses its address.
-- A cache that trusts the hit returns the dead font here.
do
  package.loaded.theme = nil
  local theme = require 'theme'
  local ImGui = fake_imgui()

  -- Both visits use the same key, which is what a recycled address means.
  local address = 'ctx-recycled'

  local first = theme.font(address, ImGui)
  theme.begin_frame(address, ImGui)   -- the tool draws
  theme.end_frame(address, ImGui)

  -- The tool closes. REAPER hands the same address to the next context.
  ImGui.release(address)

  local second = theme.font(address, ImGui)
  check(second ~= first,
    'a recycled context must get a new font, not the dead one')
  check(ImGui.created == 2,
    'the font is recreated for the new context, got ' .. ImGui.created)
  check(ImGui.attached == 2,
    'the new font is attached to the new context, got ' .. ImGui.attached)

  -- The actual failure mode: PushFont with a dead handle. The fake raises
  -- exactly where REAPER did.
  theme.begin_frame(address, ImGui)
  theme.end_frame(address, ImGui)
  check(ImGui.pushed[#ImGui.pushed] == second,
    'the frame draws with the live font')
end

-- Two tools open in sequence, each with its own context: neither may be
-- handed the other's font.
do
  package.loaded.theme = nil
  local theme = require 'theme'
  local ImGui = fake_imgui()

  local editor = theme.font('ctx-editor', ImGui)
  local export = theme.font('ctx-export', ImGui)
  check(editor ~= export, 'each context gets its own font')

  ImGui.release('ctx-editor')
  check(theme.font('ctx-export', ImGui) == export,
    'releasing one context must not invalidate another context\'s font')
end

H.pass('theme font cache: reused while a context lives, recreated when its ' ..
       'address is recycled, isolated per context (3 groups)')
