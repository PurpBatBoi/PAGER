# Purp’s Advanced GS Editor for REAPER (PAGER)

A [REAPER](https://www.reaper.fm/) ReaScript suite for controlling a Roland
SC-8850 with GS System Exclusive (SysEx) messages. It previews your edits on
the hardware as you make them, and writes messages into the active MIDI take
when you ask it to.

One action, **PAGER**, opens a launcher holding the whole suite:

```
[Part Editor] [Patch Editor] [Drum Editor] [Effects Editor] [MIDI-Export]
```

Effects Editor and MIDI-Export are available now; the Part, Patch and Drum
editors are shown grayed out until they are written. Choosing a tool closes
the launcher and opens that tool, and closing the tool brings the launcher
back, so only one window is ever on screen.

## Features

- Master level, pan, key shift, and tune controls
- GS, GM1, and GM2 reset messages
- 65 insertion-effect types and their parameters
- Per-part insertion-effect assignment
- Two-band global EQ, with per-part EQ on/off and built-in curves
- Reverb, chorus, and delay controls with macro presets
- Named presets stored in a shareable JSON file
- A vendor-neutral, multi-port MIDI exporter — 16 channels per port, so a
  four-port SC-8850 exports all 64 parts (prototype)

## Requirements

- REAPER
- [ReaPack](https://reapack.com/), the REAPER extension used to install
  ReaImGui
- [ReaImGui](https://codeberg.org/cfillion/reaimgui), version 0.10 or newer
- [js_ReaScriptAPI](https://forum.cockos.com/showthread.php?t=212174)
- [MIDIUtils](https://github.com/jeremybernstein/ReaScripts), from the
  sockmonkey72 MIDI scripts in ReaPack, used by the MIDI exporter
- A Roland SC-8850, for the effects editor. The MIDI exporter is
  vendor-neutral and needs no particular hardware.

## Installation

1. Install ReaPack in REAPER.
2. Use ReaPack to install ReaImGui, version 0.10 or newer, js_ReaScriptAPI,
   and the sockmonkey72 MIDI scripts (for MIDIUtils).
3. Open **Extensions > ReaPack > Manage repositories**.
4. Click **Import repositories** and add:
   `https://raw.githubusercontent.com/PurpBatBoi/PAGER/main/index.xml`
5. Click **Apply**, then open **Browse packages** and install **PAGER**.
6. In REAPER, open the action list and run `PAGER/pager.lua`. That is the
   only action the package installs; the tools open from its launcher.

## Use

Run the **PAGER** action and pick a tool.

The launcher and the tool take turns: picking a tool closes the launcher, and
closing the tool — with its **Back to PAGER** button, with Cancel in MIDI
Export, or with the window's close button — opens the launcher again. A
successful export closes MIDI Export and shows `Exported: <filename>` on the
launcher's status line instead of a popup.

Values you set are remembered for the rest of the REAPER session, so
reopening a tool puts back what you left, including the tab you were on. Each
project tab keeps its own values, and everything resets when REAPER closes.
Restored values are not sent anywhere: the Effects Editor says "Restored
values; not sent to hardware." until your next edit.

### Effects Editor

Select a MIDI item or open a MIDI editor, position the edit cursor, then open
**Effects Editor** from the launcher.

Editing and inserting are two separate things:

- **Editing previews on the hardware.** Releasing a slider, choosing an
  insertion-effect type, or choosing a preset sends that state to the track's
  configured MIDI hardware output. Nothing is written to the MIDI take.
  Messages are paced 20 ms apart, and a newer selection replaces whatever is
  left of an older one.
- **Insert writes to the MIDI take.** The Insert buttons write at the edit
  cursor and send nothing, because the preview already happened while you
  were editing. Events in a run are spaced by the **MIDI tick gap** setting,
  which is PPQ spacing on the project timeline, not hardware timing.
- **You can write less than everything.** Next to the plain Insert buttons:
  - **Insert only changed** on the Master tab writes just the master values
    you have moved since your last insert, so changing the pan does not also
    rewrite level, key-shift and tune with values the device already holds.
    It greys out when nothing has moved, and both Insert buttons clear the
    marks once they have written.
  - **Insert only changes** on the Insertion Effects and system-effect tabs
    writes the parameters that differ from the selected preset. If a
    matching run already sits at the cursor each parameter is updated in its
    own slot in that run; otherwise the changed values are packed together
    from the cursor. Either way it writes only what you edited.
- **The reset buttons do both.** GS Reset, GM1 Reset and GM2 Reset each send
  to the hardware and write into the take. If the track has no hardware
  output the reset is still written, and the status line says so.
- **The part checkboxes are the exception.** "Parts using EFX" and "Parts
  using EQ" write to the MIDI take the moment they are clicked.

A track needs a MIDI hardware output configured for previews to be audible.
Without one, editing still works and the status line reports that nothing was
sent; REAPER gives no delivery confirmation either way, so the status line
reports what was submitted, not what the device received.

### MIDI Export

> **Prototype.** This tool is still early: expect bugs and missing features.
> Check anything it writes before you rely on it, and keep the project file
> you exported from.

**MIDI-Export** writes a standard MIDI file from the project or the time
selection. It is vendor-neutral and needs no particular hardware, and its
options are remembered per project tab like the editor's. A failed export
stays open with the reason on its status line, so the settings that caused it
are still in front of you.

It is **multi-port**, so an export is not limited to 16 channels. Each
track's port comes from its MIDI hardware output, and when the selection
spans more than one device the file carries an `FF 21` port meta per track,
which is what players read to keep two tracks on the same channel apart.
Four ports of 16 channels is 64 parts — a full SC-8850 — and nothing caps
it at four.

Two things to know about it:

- Ports are written by **Type 1** only. Type 0 is a single track by
  definition, so it has nowhere to put the port metas and everything
  collapses onto one port.
- A track with no MIDI hardware output set inherits its parent folder's, and
  falls back to port 0. Ports are renumbered densely from zero in device
  order, so what the file preserves is which tracks share a port, not
  REAPER's own device numbers.

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

"json.lua" library from https://github.com/rxi/json.lua, vendored at `lib/json.lua`

## License

MIT. See [LICENSE](LICENSE).
