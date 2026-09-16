-- Check: efx_changed_params picks out exactly the insertion parameters that
-- differ from a preset's baseline, with the slot numbers a run needs to
-- write them back in place.
--
-- This is the diff insert_efx_preset_changes ("Insert only changes") is
-- built on. Two things make it easy to get wrong: EFX_SUB parameters must
-- slot in *after* every ps entry (slot = #ps + i - 1, not i - 1), and a
-- baseline has to be clamped the same way insert_efx_preset clamps it before
-- comparing, or a preset saved under a wider range would look changed when
-- it is not.
--
-- efx_changed_params, clamp and EFX_SUB are lifted out of
-- effects_editor.lua rather than copied, and ps is the real efx_params.lua
-- data for one effect type. Run with any Lua:
--   lua editor/test_efx_changes.lua

local dir = arg and arg[0] and arg[0]:match('^(.*)[/\\]') or 'tests'
local EDITOR = dir .. '/../editor/'
package.path = EDITOR .. '?.lua;' .. dir .. '/../lib/?.lua;' .. package.path

local EFX_PARAMS = require 'efx_params'

-- Lift efx_changed_params plus the two small pieces its body reaches for:
-- clamp, and EFX_SUB (the sub-parameter list every effect shares). If any
-- of the three move or change shape, this fails loudly instead of quietly
-- testing a stale copy.
local function load_from_editor()
  local path = EDITOR .. 'effects_editor.lua'
  local f = assert(io.open(path, 'r'), 'cannot open ' .. path)
  local src = f:read('a')
  f:close()

  local clamp_body = src:match('\n(local function clamp%(v, lo, hi%).-\nend)\n')
  local sub_body = src:match('\n(local EFX_SUB = {.-\n})\n')
  local fn_body = src:match('\n(local function efx_changed_params%(p, ps%).-\nend)\n')
  assert(clamp_body, 'clamp not found -- was it renamed?')
  assert(sub_body, 'EFX_SUB not found -- was it renamed or moved?')
  assert(fn_body, 'efx_changed_params not found in ' .. path ..
                   ' -- was it renamed? this test must follow it')

  -- math, tonumber and ipairs are all the lifted code reaches for.
  local chunk = assert(load(
    clamp_body .. '\n' .. sub_body .. '\n' .. fn_body ..
    '\nreturn efx_changed_params, EFX_SUB',
    'efx_changed_params', 't',
    { math = math, tonumber = tonumber, ipairs = ipairs }))
  return chunk()
end

local efx_changed_params, EFX_SUB = load_from_editor()

-- Real type-2 params: Low/Hi Freq+Gain, M1/M2 Freq+Q+Gain, Level -- 11 in all.
local ps = EFX_PARAMS[2]
assert(#ps == 11, 'this test assumes EFX type 2 has 11 parameters')

local function defaults(list)
  local vals = {}
  for i, e in ipairs(list) do
    e.value = e.default
    vals[i] = e.default
  end
  return vals
end

-- Case 1: a preset identical to the current values changes nothing.
local ps_baseline = defaults(ps)
local sub_baseline = defaults(EFX_SUB)
local p1 = { name = 'Identical', vals = ps_baseline, sub = sub_baseline }
local changed1 = efx_changed_params(p1, ps)
assert(changed1 ~= nil, 'a well-formed preset must not error')
assert(#changed1 == 0, 'identical values must report no changes, got ' .. #changed1)

-- Case 2: one ps parameter and one EFX_SUB parameter are edited away from
-- that same baseline. Each changed entry must carry the *current* value
-- (what is on screen now), not the preset's baseline, with the right
-- address and the right slot -- EFX_SUB entries slot in after every ps
-- entry, not from zero.
defaults(ps); defaults(EFX_SUB)
ps[2].value = ps[2].max           -- 'Low Gain' (default 69, max 76), ps[2] -> expected slot 1
EFX_SUB[2].value = EFX_SUB[2].max -- 'Send Level To Chorus' (default 0, max 127)
local p2 = { name = 'TwoChanged', vals = ps_baseline, sub = sub_baseline }
local changed2 = efx_changed_params(p2, ps)
assert(#changed2 == 2, 'exactly two parameters were changed, got ' .. #changed2)

local by_addr = {}
for _, c in ipairs(changed2) do by_addr[c.addr[3]] = c end

local low_gain = by_addr[ps[2].addr]
assert(low_gain, 'Low Gain (addr ' .. ps[2].addr .. ') must be in the changed list')
assert(low_gain.slot == 1, 'Low Gain is ps[2], so its slot must be 1 (0-based), got ' .. low_gain.slot)
assert(low_gain.value == ps[2].value, 'must carry the current value, not the baseline')
assert(low_gain.addr[1] == 0x40 and low_gain.addr[2] == 0x03, 'insertion params address 40 03')

local chorus_send = by_addr[EFX_SUB[2].addr]
assert(chorus_send, 'Send Level To Chorus (addr ' .. EFX_SUB[2].addr .. ') must be in the changed list')
assert(chorus_send.slot == #ps + 1,
  'an EFX_SUB entry must slot after every ps entry: expected ' .. (#ps + 1) ..
  ', got ' .. chorus_send.slot)

-- Case 3: a baseline outside the parameter's range is clamped before
-- comparing -- a preset saved under a wider range must not look changed
-- just because its raw number exceeds today's max.
defaults(ps); defaults(EFX_SUB)
local vals3 = defaults(ps)
vals3[1] = ps[1].max + 50 -- an out-of-range baseline for Low Freq
ps[1].value = ps[1].max   -- the clamped form of that same baseline
local p3 = { name = 'OutOfRange', vals = vals3, sub = defaults(EFX_SUB) }
local changed3 = efx_changed_params(p3, ps)
assert(#changed3 == 0,
  'a baseline that clamps to the current value must not read as changed, got ' ..
  #changed3)

-- Case 4: a malformed preset value is reported, not crashed on.
local vals4 = defaults(ps)
vals4[1] = 'not a number'
local p4 = { name = 'Bad', vals = vals4, sub = defaults(EFX_SUB) }
local changed4, err4 = efx_changed_params(p4, ps)
assert(changed4 == nil, 'an invalid preset value must be rejected, not diffed')
assert(err4:find('invalid parameter value'), 'the error must name the problem, got: ' .. tostring(err4))

print('ok: efx_changed_params picks the right params, slots, and clamps baselines (4 cases, against the real function)')
