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

local function part_efx_addr(part)
  local block = PART_BLOCK[part]
  assert(block and block >= 0 and block <= 0xF, 'invalid SC-8850 part block')
  local middle = 0x40 + block
  assert(middle >= 0x40 and middle <= 0x4F, 'part EFX address left block')
  return { 0x40, middle, 0x22 }
end

assert(part_efx_addr(10)[2] == 0x40, 'part 10 must use block 0')
assert(part_efx_addr(16)[2] == 0x4F, 'part 16 must use block F')

return {
  DEV = DEV, ROLAND_ID = ROLAND_ID, MODEL_GS = MODEL_GS, CMD_DT1 = CMD_DT1,
  GS_RESET = GS_RESET, PART_BLOCK = PART_BLOCK,
  checksum = checksum, dt1 = dt1, is_dt1_at = is_dt1_at,
  master_volume = master_volume, master_tune = master_tune,
  hz_to_cents_x10 = hz_to_cents_x10, part_efx_addr = part_efx_addr,
}
