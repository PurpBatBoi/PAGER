# Purp’s Advanced GS Editor for REAPER (PAGER)

A [REAPER](https://www.reaper.fm/) ReaScript for controlling a Roland SC-8850
with GS System Exclusive (SysEx) messages. It can write messages into the
active MIDI take at the edit cursor, or send them directly to the track's MIDI
hardware output.

## Features

- Master level, pan, key shift, and tune controls
- GS, GM1, and GM2 reset messages
- 65 insertion-effect types and their parameters
- Per-part insertion-effect assignment
- Two-band global EQ, with per-part EQ on/off and built-in curves
- Reverb, chorus, and delay controls with macro presets
- Named presets stored in a shareable JSON file

## Requirements

- REAPER
- [ReaPack](https://reapack.com/), the REAPER extension used to install
  ReaImGui
- [ReaImGui](https://codeberg.org/cfillion/reaimgui), version 0.10 or newer
- A Roland SC-8850 

## Installation

1. Install ReaPack in REAPER.
2. Use ReaPack to install ReaImGui, version 0.10 or newer.
3. Open **Extensions > ReaPack > Manage repositories**.
4. Click **Import repositories** and add:
   `https://raw.githubusercontent.com/PurpBatBoi/PAGER/main/index.xml`
5. Click **Apply**, then open **Browse packages** and install **PAGER**.
6. In REAPER, open the action list and run `PAGER/effects_editor.lua`.

## Use

Select a MIDI item or open a MIDI editor, position the edit cursor, then run
the script. By default it writes SysEx events to the active MIDI take. Enable
**Live hardware send** in the Settings tab to send directly to the track's
configured MIDI hardware output.

## Presets

Presets you save with the **+** button go into one file, outside the PAGER
install so they survive a ReaPack update:

```
<REAPER resource path>/presets/PAGER/user_presets.json
```

The resource path is the folder REAPER opens from **Options > Show REAPER
resource path in explorer/finder**. By default:

| | |
|---|---|
| Windows | `%APPDATA%\REAPER\presets\PAGER\user_presets.json` |
| macOS | `~/Library/Application Support/REAPER/presets/PAGER/user_presets.json` |
| Linux | `~/.config/REAPER/presets/PAGER/user_presets.json` |

The folder and file are created the first time you save a preset. The path is
also shown in the tooltip on the **+** button, and in the status line after a
save.

It is plain JSON, one object per preset, so the file can be edited by hand or
shared. Insertion-effect presets carry `efx`; Reverb, Chorus, Delay and EQ
presets carry `fx`:

```json
[
  { "efx": "Stereo-EQ", "efx_index": 2, "name": "Warm",
    "vals": [60, 65, 67, 70, 66, 63, 60, 59, 2, 64, 127],
    "sub":  [40, 0, 0, 0, 64, 0, 64, 1] },
  { "fx": "EQ", "fx_index": 4, "name": "Air",
    "macro": 1,
    "vals": [0, 64, 0, 70] }
]
```

Values are raw SysEx bytes, matching the manual's ranges rather than the
displayed units — an EQ gain of `70` is the `+6 dB` the slider shows, since
`64` is 0 dB.

Hand-edits are checked rather than trusted: a preset whose value count does
not match its effect, or a file that is not valid JSON, is reported in the
status line and ignored, so a bad edit cannot put wrong bytes on the wire.

The built-in presets (Reverb's `Room 1`, the EQ curves, and each effect's
`Default`) are compiled in and are not stored in this file.

## Third-party

"json.lua" library from https://github.com/rxi/json.lua

## License

MIT. See [LICENSE](LICENSE).
