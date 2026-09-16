-- Reverb Presets.
local REVERB = {
  { 'Room 1',        { 0, 3, 64, 80, 0,  0 } },
  { 'Room 2',        { 1, 4, 64, 56, 0,  0 } },
  { 'Room 3',        { 2, 0, 64, 64, 0,  0 } },
  { 'Hall 1',        { 3, 4, 64, 72, 0,  0 } },
  { 'Hall 2',        { 4, 0, 64, 64, 0,  0 } },
  { 'Plate',         { 5, 0, 64, 88, 0,  0 } },
  { 'Delay',         { 6, 0, 64, 32, 40, 0 } },
  { 'Panning Delay', { 7, 0, 64, 64, 32, 0 } },
}

-- Chorus presets.
local CHORUS = {
  { 'Chorus 1',       { 0, 64,  0, 112,   3,   5, 0, 0 } },
  { 'Chorus 2',       { 0, 64,  5,  80,   9,  19, 0, 0 } },
  { 'Chorus 3',       { 0, 64,  8,  80,   3,  19, 0, 0 } },
  { 'Chorus 4',       { 0, 64, 16,  64,   9,  16, 0, 0 } },
  { 'Feedback Chorus',{ 0, 64, 64, 127,   2,  24, 0, 0 } },
  { 'Flanger',        { 0, 64,112, 127,   1,   5, 0, 0 } },
  { 'Short Delay',    { 0, 64,  0, 127,   0, 127, 0, 0 } },
  { 'Short Delay[FB]',{ 0, 64, 80, 127,   0, 127, 0, 0 } },
}

-- Delay presets.
local DELAY = {
  { 'Delay 1',     { 0,  97,  1,  1, 127,   0,  0, 64, 80,  0 } },
  { 'Delay 2',     { 0, 106,  1,  1, 127,   0,  0, 64, 80,  0 } },
  { 'Delay 3',     { 0, 115,  1,  1, 127,   0,  0, 64, 72,  0 } },
  { 'Delay 4',     { 0,  83,  1,  1, 127,   0,  0, 64, 72,  0 } },
  { 'Pan Delay 1', { 0, 105, 12, 24,   0, 125, 60, 64, 74,  0 } },
  { 'Pan Delay 2', { 0, 109, 12, 24,   0, 125, 60, 64, 71,  0 } },
  { 'Pan Delay 3', { 0, 115, 12, 24,   0, 120, 64, 64, 73,  0 } },
  { 'Pan Delay 4', { 0,  93, 12, 24,   0, 120, 64, 64, 72,  0 } },
  { 'Delay to Rev.',{0, 109, 12, 24,   0, 114, 60, 64, 61, 36 } },
  { 'PanRepeat',    { 0, 110, 21, 32,  97, 127, 67, 64, 40,  0 } },
}

-- Built-in EQ curves, as raw bytes: { low freq, low gain, high freq, high gain }.
-- Gain 64 (0x40) is flat; each step is 1 dB. See docs/SC-8850_OM.pdf p.86/236.
local EQ = {
  { 'Flat',       { 0, 64, 0, 64 } },
  { 'Bass Boost', { 0, 70, 0, 64 } },  -- low +6 dB @ 200 Hz
  { 'Bright',     { 0, 64, 0, 70 } },  -- high +6 dB @ 3 kHz
  { 'Loudness',   { 0, 70, 0, 68 } },  -- low +6, high +4
  { 'Scoop',      { 1, 58, 0, 68 } },  -- low -6 @ 400 Hz, high +4
  { 'Telephone',  { 1, 52, 1, 52 } },  -- both -12
}

return {
  { 'Reverb', {
    { name = 'Macro',            addr = 0x30, min = 0, max = 7,   default = 0x04,
      macros = REVERB },
    { name = 'Character',        addr = 0x31, min = 0, max = 7,   default = 0x04 },
    { name = 'Pre-LPF',          addr = 0x32, min = 0, max = 7,   default = 0x00 },
    { name = 'Level',            addr = 0x33, min = 0, max = 127, default = 0x40 },
    { name = 'Time',             addr = 0x34, min = 0, max = 127, default = 0x40 },
    { name = 'Delay Feedback',   addr = 0x35, min = 0, max = 127, default = 0x00 },
    { name = 'Predelay Time',    addr = 0x37, min = 0, max = 127, default = 0x00 },
  }, addr_mid = 0x01 },
  { 'Chorus', {
    { name = 'Macro',            addr = 0x38, min = 0, max = 7,   default = 0x02,
      macros = CHORUS },
    { name = 'Pre-LPF',          addr = 0x39, min = 0, max = 7,   default = 0x00 },
    { name = 'Level',            addr = 0x3A, min = 0, max = 127, default = 0x40 },
    { name = 'Feedback',         addr = 0x3B, min = 0, max = 127, default = 0x08 },
    { name = 'Delay',            addr = 0x3C, min = 0, max = 127, default = 0x50 },
    { name = 'Rate',             addr = 0x3D, min = 0, max = 127, default = 0x03 },
    { name = 'Depth',            addr = 0x3E, min = 0, max = 127, default = 0x13 },
    { name = 'Send To Reverb',   addr = 0x3F, min = 0, max = 127, default = 0x00 },
    { name = 'Send To Delay',    addr = 0x40, min = 0, max = 127, default = 0x00 },
  }, addr_mid = 0x01 },
  { 'Delay', {
    { name = 'Macro',            addr = 0x50, min = 0,   max = 9,    default = 0x00,
      macros = DELAY },
    { name = 'Pre-LPF',          addr = 0x51, min = 0,   max = 7,    default = 0x00 },
    { name = 'Time Center',      addr = 0x52, min = 0x01, max = 0x73, default = 0x61 },
    { name = 'Time Ratio Left',  addr = 0x53, min = 0x01, max = 0x78, default = 0x01 },
    { name = 'Time Ratio Right', addr = 0x54, min = 0x01, max = 0x78, default = 0x01 },
    { name = 'Level Center',     addr = 0x55, min = 0,   max = 127,  default = 0x7F },
    { name = 'Level Left',       addr = 0x56, min = 0,   max = 127,  default = 0x00 },
    { name = 'Level Right',      addr = 0x57, min = 0,   max = 127,  default = 0x00 },
    { name = 'Level',            addr = 0x58, min = 0,   max = 127,  default = 0x40 },
    { name = 'Feedback',         addr = 0x59, min = 0,   max = 127,  default = 0x50 },
    { name = 'Send To Reverb',   addr = 0x5A, min = 0,   max = 127,  default = 0x00 },
  }, addr_mid = 0x01 },
  -- Global EQ, manual p.86/236 (40 02 xx). One shared set, not per-part --
  -- the per-part switch (40 4x 20) is separate, driven by the 16 checkboxes
  -- on the EQ tab, not by this block. No hardware macro register exists, so
  -- 'Preset' is addr = nil and each_preset_event/insert_system_preset must
  -- skip emitting it when the address is absent.
  { 'EQ', {
    { name = 'Preset',       addr = nil, min = 0, max = #EQ - 1, default = 0,
      macros = EQ },
    { name = 'EQ Low Freq',  addr = 0x00, min = 0,  max = 1,  default = 0,
      enum = { '200 Hz', '400 Hz' } },
    { name = 'EQ Low Gain',  addr = 0x01, min = 52, max = 76, default = 64,
      db = true },
    { name = 'EQ High Freq', addr = 0x02, min = 0,  max = 1,  default = 0,
      enum = { '3 kHz', '6 kHz' } },
    { name = 'EQ High Gain', addr = 0x03, min = 52, max = 76, default = 64,
      db = true },
  }, addr_mid = 0x02 },
}
