-- Check: a preset emits its events in one fixed order, and the same ones on
-- the item path as on the live path.
--
-- each_preset_event is the single walk both paths drive, so a drift in its
-- order or count desynchronises what the item holds from what the hardware
-- hears -- silently, since either alone still looks plausible. The case that
-- makes this delicate is EQ: it has no hardware macro register, so its macro
-- entry carries addr = nil and it must emit no macro event, which shifts
-- every parameter's slot by one against the other three blocks.
--
-- The walk is lifted out of effects_editor.lua rather than copied, and the
-- blocks are the real fx_blocks.lua. Run with any Lua:
--   lua editor/test_preset_walk.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
local EDITOR = dir .. '/../editor/'
package.path = EDITOR .. '?.lua;' .. dir .. '/../lib/?.lua;' .. package.path

local FX_BLOCKS = require 'fx_blocks'

-- Lift the real each_preset_event. Loading the whole editor would need
-- REAPER, so compile just this function: if its body changes, this runs the
-- change rather than a stale copy.
local function load_walk()
  local path = EDITOR .. 'effects_editor.lua'
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local src = f:read('a')
  f:close()
  local body = src:match('\n(local function each_preset_event%(blk, entry, choice, emit%).-\nend)\n')
  assert(body, 'each_preset_event not found in ' .. path ..
                ' -- was it renamed? this test must follow it')
  -- ipairs is all the walk reaches for; keeping the environment this small
  -- means the lifted function cannot quietly grow a dependency on editor
  -- state without this test noticing.
  local chunk = assert(load(body .. '\nreturn each_preset_event',
                            'each_preset_event', 't', { ipairs = ipairs }))
  return chunk()
end

local each_preset_event = load_walk()

local function block(name)
  for _, blk in ipairs(FX_BLOCKS) do
    if blk[1] == name then return blk end
  end
  error('no block named ' .. name)
end

-- Collect what one preset emits, in order.
local function walk(blk, choice)
  local entry = blk[2][1]
  local events = {}
  local n, err = each_preset_event(blk, entry, choice, function(i, addr, value)
    events[#events + 1] = { i = i, addr = addr, value = value }
    return true
  end)
  return n, events, err
end

-- A block with a macro register writes the macro first, then one event per
-- parameter the preset supplies, on consecutive slots from zero.
for _, name in ipairs({ 'Reverb', 'Chorus', 'Delay' }) do
  local blk = block(name)
  local entry = blk[2][1]
  local n, events = walk(blk, 1)
  assert(n == #events, name .. ': returned count must match events emitted')
  assert(events[1].addr[3] == entry.addr,
         name .. ': the first event must be the macro register')
  assert(events[1].value == 0, name .. ': preset 1 selects macro value 0')
  for i, ev in ipairs(events) do
    assert(ev.i == i - 1, name .. ': slots must run 0,1,2... got ' .. ev.i)
    assert(ev.addr[1] == 0x40 and ev.addr[2] == blk.addr_mid,
           name .. ': every event addresses this block')
    assert(ev.value >= 0 and ev.value <= 127,
           name .. ': ' .. ev.value .. ' does not fit in a MIDI data byte')
  end
end

-- EQ has no macro register, so the walk must emit parameters only -- never a
-- macro event with a nil address, and never an empty slot where one would be.
local eq = block('EQ')
assert(eq[2][1].addr == nil, 'this test assumes EQ carries no macro register')
local eq_n, eq_events = walk(eq, 1)
assert(eq_n == #eq_events, 'EQ: returned count must match events emitted')
for i, ev in ipairs(eq_events) do
  assert(ev.i == i - 1, 'EQ: slots must start at 0 with no macro gap, got ' .. ev.i)
  assert(ev.addr[3] ~= nil, 'EQ: emitted an event with no address')
end

-- The walk writes each preset value back onto its entry, so what the panel
-- shows matches what was written. Checked on Reverb preset 2, whose values
-- differ from preset 1.
local rev = block('Reverb')
walk(rev, 1)
local _, second = walk(rev, 2)
local vi = 0
for _, e in ipairs(rev[2]) do
  if not e.macros then
    vi = vi + 1
    local expected = rev[2][1].macros[2][2][vi]
    if expected then
      assert(e.value == expected,
             'Reverb: ' .. e.name .. ' should now read ' .. expected ..
             ', reads ' .. tostring(e.value))
    end
  end
end
assert(#second > 1, 'Reverb preset 2 should emit more than the macro alone')

-- An emit that refuses aborts the walk: the live path returns false when a
-- send fails, and the rest of the run must not be written as if it had gone.
local blk = block('Chorus')
local seen = 0
local n, err = each_preset_event(blk, blk[2][1], 1, function()
  seen = seen + 1
  if seen == 3 then return false, 'device went away' end
  return true
end)
assert(n == nil, 'a refused emit must report failure, got ' .. tostring(n))
assert(err == 'device went away', 'the emit error must reach the caller')
assert(seen == 3, 'the walk must stop on the refusing event, ran ' .. seen)

print('ok: preset walk order, EQ macro-less case, and abort (5 cases)')
