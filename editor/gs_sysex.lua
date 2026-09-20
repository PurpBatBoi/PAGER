-- Pure Roland GS SysEx math. Payloads exclude F0/F7; REAPER adds those for
-- item events, while the live hardware path frames them at the send boundary.

local DEV = 0x10 -- device ID, 0x00-0x1F (SC-8850 default 0x10)
local ROLAND_ID = 0x41
local MODEL_GS  = 0x42
local CMD_DT1   = 0x12 -- Data Set 1, the only command this script sends

local function checksum(bytes)
  local sum = 0
  for _, b in ipairs(bytes) do sum = sum + b end
  return (128 - sum % 128) & 0x7F
end

local function dt1(addr_and_data)
  local msg = { ROLAND_ID, DEV, MODEL_GS, CMD_DT1 }
  for _, b in ipairs(addr_and_data) do msg[#msg + 1] = b end
  msg[#msg + 1] = checksum(addr_and_data)
  return string.char(table.unpack(msg))
end

local GS_RESET = { 0x40, 0x00, 0x7F, 0x00 }
assert(dt1(GS_RESET):byte(-1) == 0x41, 'GS Reset checksum should be 0x41')
assert(checksum({ 0x40, 0x01, 0x30, 0x02 }) == 0x0D,
       'manual p.245 example should be 0x0D')

local function is_dt1_at(msg, addr)
  return msg and #msg >= 7
     and msg:byte(1) == ROLAND_ID and msg:byte(3) == MODEL_GS
     and msg:byte(5) == addr[1]
     and msg:byte(6) == addr[2]
     and msg:byte(7) == addr[3]
end

local function master_volume(vol)
  return string.char(0x7F, 0x7F, 0x04, 0x01, 0x00, vol & 0x7F)
end

local function master_tune(cents_x10)
  cents_x10 = math.max(-1000, math.min(1000, cents_x10))
  local v = cents_x10 + 0x400
  return dt1({ 0x40, 0x00, 0x00,
               (v >> 12) & 0xF, (v >> 8) & 0xF, (v >> 4) & 0xF, v & 0xF })
end

assert(master_tune(0):sub(5, 8) == string.char(0x40, 0x00, 0x00, 0x00),
       'A440 should encode as 00 04 00 00 after the address')

local function hz_to_cents_x10(hz)
  return math.floor(1200 * math.log(hz / 440.0, 2) * 10 + 0.5)
end

local PART_BLOCK = { 0x1, 0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8,
                     0x9, 0x0, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF }

-- Address of a per-part switch: 40 4x lo, where x is the part's block
-- nibble (not its part number -- see PART_BLOCK) and lo picks the switch.
local function part_addr(part, lo)
  local block = PART_BLOCK[part]
  assert(block and block >= 0 and block <= 0xF, 'invalid SC-8850 part block')
  local middle = 0x40 + block
  assert(middle >= 0x40 and middle <= 0x4F, 'part address left block')
  return { 0x40, middle, lo }
end

local function part_efx_addr(part) return part_addr(part, 0x22) end
local function part_eq_addr(part)  return part_addr(part, 0x20) end

-- The Part Editor reaches two more address families on the same block nibble.
-- 40 1x is the Patch Part block -- level, pan, the tone modifiers, tuning --
-- and 40 2x is the Part's bend block. Both are port-local: the same bytes
-- sent through hardware Port B address Group B, so nothing here encodes a
-- group (manual p.237). part_addr is not reused because it hard-codes the
-- 0x40 switch block in its middle byte.
local function part_block(part)
  local block = PART_BLOCK[part]
  assert(block and block >= 0 and block <= 0xF, 'invalid SC-8850 part block')
  return block
end

local function part_param_addr(part, lo)
  return { 0x40, 0x10 + part_block(part), lo }
end

local function part_bend_addr(part, lo)
  return { 0x40, 0x20 + part_block(part), lo }
end

assert(part_param_addr(1, 0x19)[2] == 0x11, 'part 1 level must use block 1')
assert(part_param_addr(10, 0x19)[2] == 0x10, 'part 10 must use block 0')
assert(part_param_addr(16, 0x19)[2] == 0x1F, 'part 16 must use block F')
assert(part_bend_addr(1, 0x10)[2] == 0x21, 'part 1 bend must use block 1')
assert(part_bend_addr(10, 0x10)[2] == 0x20, 'part 10 bend must use block 0')
assert(part_bend_addr(16, 0x10)[2] == 0x2F, 'part 16 bend must use block F')

assert(part_efx_addr(10)[2] == 0x40, 'part 10 must use block 0')
assert(part_efx_addr(16)[2] == 0x4F, 'part 16 must use block F')
assert(part_eq_addr(3)[2] == 0x43, 'part 3 EQ must use block 3')

-- Part 1 EQ ON/OFF, confirmed against hardware:
--   ON  F0 41 10 42 12 40 41 20 01 5E F7
--   OFF F0 41 10 42 12 40 41 20 00 5F F7
-- (F0/F7 are added by send_live; dt1 returns the payload between them.) The
-- low byte is 0x20, not 0x22 -- the EFX switch two addresses over on the same
-- part block -- so these pin the byte a copy-paste from EFX would get wrong.
local function eq_on_payload(part, on)
  local a = part_eq_addr(part)
  return dt1({ a[1], a[2], a[3], on and 1 or 0 })
end

assert(eq_on_payload(1, true) ==
       string.char(0x41, 0x10, 0x42, 0x12, 0x40, 0x41, 0x20, 0x01, 0x5E),
       'part 1 EQ ON must match the hardware capture')
assert(eq_on_payload(1, false) ==
       string.char(0x41, 0x10, 0x42, 0x12, 0x40, 0x41, 0x20, 0x00, 0x5F),
       'part 1 EQ OFF must match the hardware capture')
assert(checksum({ 0x40, 0x02, 0x01, 0x46 }) == 0x77, 'manual p.87 example')

-- The three address bytes of a DT1 payload, or nil when the payload is not
-- one. is_dt1_at answers "is this that address"; this answers "which address
-- is this", which is what the Part Editor needs to recognise its own previous
-- write at a tick without knowing in advance which parameter put it there.
-- Payloads exclude F0/F7 here, exactly as take events store them.
local function dt1_addr_of(msg)
  if type(msg) ~= 'string' or #msg < 8 then return nil end
  if msg:byte(1) ~= ROLAND_ID or msg:byte(3) ~= MODEL_GS then return nil end
  if msg:byte(4) ~= CMD_DT1 then return nil end
  return { msg:byte(5), msg:byte(6), msg:byte(7) }
end

do
  local a = dt1_addr_of(eq_on_payload(1, true))
  assert(a and a[1] == 0x40 and a[2] == 0x41 and a[3] == 0x20,
         'dt1_addr_of must read back the address eq_on_payload wrote')
end
assert(dt1_addr_of('short') == nil, 'dt1_addr_of must reject a short payload')
assert(dt1_addr_of(master_volume(64)) == nil,
       'dt1_addr_of must reject a universal-SysEx payload')

return {
  DEV = DEV, ROLAND_ID = ROLAND_ID, MODEL_GS = MODEL_GS, CMD_DT1 = CMD_DT1,
  GS_RESET = GS_RESET, PART_BLOCK = PART_BLOCK,
  checksum = checksum, dt1 = dt1, is_dt1_at = is_dt1_at,
  master_volume = master_volume, master_tune = master_tune,
  hz_to_cents_x10 = hz_to_cents_x10,
  part_addr = part_addr, part_efx_addr = part_efx_addr,
  part_eq_addr = part_eq_addr, part_block = part_block,
  part_param_addr = part_param_addr, part_bend_addr = part_bend_addr,
  dt1_addr_of = dt1_addr_of,
}
