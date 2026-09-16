-- json.lua
-- Copyright (c) 2020 rxi
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy of
-- this software and associated documentation files (the "Software"), to deal in
-- the Software without restriction, including without limitation the rights to
-- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
-- of the Software, and to permit persons to whom the Software is furnished to do
-- so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

local json = { _version = "0.1.2" }
local encode
local escapes = { ["\\"] = "\\", ["\""] = "\"", ["\b"] = "b", ["\f"] = "f", ["\n"] = "n", ["\r"] = "r", ["\t"] = "t" }
local inv = { ["/"] = "/" }
for k, v in pairs(escapes) do inv[v] = k end
local function escape(c) return "\\" .. (escapes[c] or ("u%04x"):format(c:byte())) end
local function enc(v, stack)
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' then return tostring(v) end
  if t == 'string' then return '"' .. v:gsub('[%z\1-\31\\"]', escape) .. '"' end
  if t == 'number' then
    if v ~= v or v <= -math.huge or v >= math.huge then error('unexpected number value') end
    return ('%.14g'):format(v)
  end
  if t ~= 'table' then error("unexpected type '" .. t .. "'") end
  stack = stack or {}; if stack[v] then error('circular reference') end; stack[v] = true
  local a = rawget(v, 1) ~= nil or next(v) == nil
  local out, n = {}, 0
  for k, x in pairs(v) do
    if a then if type(k) ~= 'number' then error('invalid table') end; n = n + 1
    elseif type(k) ~= 'string' then error('invalid table') end
    out[#out + 1] = a and enc(x, stack) or enc(k, stack) .. ':' .. enc(x, stack)
  end
  if a and n ~= #v then error('invalid table: sparse array') end
  stack[v] = nil
  return (a and '[' or '{') .. table.concat(out, ',') .. (a and ']' or '}')
end
function json.encode(v) return enc(v) end

local parse
local spaces = { [' '] = true, ['\t'] = true, ['\r'] = true, ['\n'] = true }
local delimiters = { [' '] = true, ['\t'] = true, ['\r'] = true, ['\n'] = true, [']'] = true, ['}'] = true, [','] = true }
local escapes_ok = { ['\\'] = true, ['/'] = true, ['"'] = true, b = true, f = true, n = true, r = true, t = true, u = true }
local function skip(s, i) while i <= #s and spaces[s:sub(i, i)] do i = i + 1 end return i end
local function fail(s, i, m) error(('%s at line %d col %d'):format(m, select(2, s:sub(1, i - 1):gsub('\n', '\n')) + 1, i - (s:sub(1, i - 1):match('.*\n()') or 1) + 1)) end
local function string_value(s, i)
  local out, j, k = '', i + 1, i + 1
  while j <= #s do
    local c = s:byte(j)
    if c < 32 then fail(s, j, 'control character in string') end
    if c == 92 then
      out = out .. s:sub(k, j - 1); j = j + 1; local x = s:sub(j, j)
      if x == 'u' then
        local h = s:match('^[dD][89aAbB]%x%x\\u%x%x%x%x', j + 1) or s:match('^%x%x%x%x', j + 1)
        if not h then fail(s, j, 'invalid unicode escape in string') end
        local n = tonumber(h:sub(1, 4), 16)
        if #h > 4 then n = (n - 0xd800) * 0x400 + tonumber(h:sub(7, 10), 16) - 0xdc00 + 0x10000 end
        if n <= 0x7f then out = out .. string.char(n) elseif n <= 0x7ff then out = out .. string.char(n // 64 + 192, n % 64 + 128) elseif n <= 0xffff then out = out .. string.char(n // 4096 + 224, (n // 64) % 64 + 128, n % 64 + 128) else out = out .. string.char(n // 262144 + 240, (n // 4096) % 64 + 128, (n // 64) % 64 + 128, n % 64 + 128) end
        j = j + #h
      else if not escapes_ok[x] then fail(s, j, 'invalid escape char') end; out = out .. (inv[x] or x) end
      k = j + 1
    elseif c == 34 then return out .. s:sub(k, j - 1), j + 1 end
    j = j + 1
  end
  fail(s, i, 'expected closing quote for string')
end
local function token(s, i) local j = i; while j <= #s and not delimiters[s:sub(j, j)] do j = j + 1 end return s:sub(i, j - 1), j end
local function array(s, i)
  local out, n = {}, 1; i = skip(s, i + 1)
  if s:sub(i, i) == ']' then return out, i + 1 end
  while true do local v; v, i = parse(s, i); out[n], n = v, n + 1; i = skip(s, i); local c = s:sub(i, i); i = skip(s, i + 1); if c == ']' then return out, i end; if c ~= ',' then fail(s, i, "expected ']' or ','") end end
end
local function object(s, i)
  local out = {}; i = skip(s, i + 1); if s:sub(i, i) == '}' then return out, i + 1 end
  while true do local k, v; if s:sub(i, i) ~= '"' then fail(s, i, 'expected string for key') end; k, i = string_value(s, i); i = skip(s, i); if s:sub(i, i) ~= ':' then fail(s, i, "expected ':' after key") end; v, i = parse(s, skip(s, i + 1)); out[k] = v; i = skip(s, i); local c = s:sub(i, i); i = skip(s, i + 1); if c == '}' then return out, i end; if c ~= ',' then fail(s, i, "expected '}' or ','") end end
end
parse = function(s, i)
  local c = s:sub(i, i)
  if c == '"' then return string_value(s, i) elseif c == '[' then return array(s, i) elseif c == '{' then return object(s, i) end
  local w, j = token(s, i); if w == 'true' then return true, j elseif w == 'false' then return false, j elseif w == 'null' then return nil, j end
  local n = tonumber(w); if n then return n, j end; fail(s, i, "unexpected character '" .. c .. "'")
end
function json.decode(s)
  if type(s) ~= 'string' then error('expected argument of type string') end
  local v, i = parse(s, skip(s, 1)); i = skip(s, i); if i <= #s then fail(s, i, 'trailing garbage') end; return v
end
return json
