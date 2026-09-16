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
- Reverb, chorus, and delay controls with macro presets
- Named Insertion Effects presets stored in a shareable JSON file

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

## Third-party

"json.lua" library from https://github.com/rxi/json.lua

## License

MIT. See [LICENSE](LICENSE).
