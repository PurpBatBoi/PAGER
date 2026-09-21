# Handoff — PAGER Part Editor

Branch `Rework`, last commit `f6a228c`. All work below is **uncommitted**.

Next session's focus: **a Settings page for the Part Editor that maps MIDI hardware
outputs to the SC-8850's A/B/C/D part groups.** That work has not started — see
[Open work](#open-work) for the design questions that block it.

## Verify first

```
python scripts/run_checks.py
```

Expect **83 `ok:` lines** and one failure: `self-test needs docs\[native]16-chs-baseline.mid`.
That fixture is missing on this machine and fails identically on a clean tree — it is
**not** caused by this work. Any other failure is a regression.

Lua is at `C:/Lua54/lua54.exe`; a single suite runs as
`"C:/Lua54/lua54.exe" tests/test_part_editor.lua`.

## What changed

New: `editor/voices.lua`, `tests/test_voices.lua`, eight `editor/*.reabank` files.
Modified: `part_editor.lua`, `part_insert.lua`, `part_messages.lua`, `part_params.lua`,
`hardware_output.lua`, `index.xml`, four test files.

Read the diff for detail. The parts not evident from it:

- **Layout** is now XG-style — left sidebar of pages (Common / Filter / Tuning /
  Vibrato) over a single column, plus an Overview tab gridding all 16 Parts.
  Channel picker sits top-right and reads `Multi`, locked, on the Overview.
- **Voices** are selectable from all four instrument maps (SC-55/88/88Pro/8850,
  selected by Bank Select LSB 1/2/3/4), grouped by Roland's sixteen GM2 categories.
  Insert writes them to REAPER's Bank/Program Select lane.
- **`Use For Rhythm`** (`40 1x 15`) added as a three-state enum: None / DRUM 1 / DRUM 2.

## Invariants — do not regress these

Each cost a debugging round-trip this session. Several are enforced by tests that will
fail loudly; the rest are here because nothing guards them yet.

1. **Preview and Insert are independent.** A settled edit sets the pending snapshot
   *before* any route is checked. An unroutable edit is still insertable. Gating the
   commit on `track` left Insert permanently greyed.
2. **Query item state before drawing anything else.** ImGui's `IsItem*` describe the
   *last item drawn*. `control_row` draws value text after its slider, so it captures
   `settled()` first. Reversing this silently breaks every slider on the per-part pages.
3. **Insert scope follows the visible tab.** On the Overview it writes every Part
   holding a pending edit; elsewhere only the Part on screen. The header's channel is
   locked to `Multi` there, so asking it alone finds nothing.
4. **Events never share a tick.** `free_slot` in `part_insert.lua` slides an insert
   forward until its ticks are free, ignoring ticks its own previous copy holds so a
   replacement stays put. The SC-8850 acts on arrival order — two SysEx writes on one
   tick let the sort decide which wins. Labels deliberately share their event's tick.
5. **A drum kit belongs to the Part Mode, not the Part.** `drum_kits[1]` and
   `drum_kits[2]` are the only two kit slots. Any number of Parts may be drum Parts;
   Parts sharing a mode share one kit and all follow a change to it. Manual p.55 is
   explicit. There is **no** two-drum-Part limit — do not add one.
6. **`is_drum(part)` derives from `values.rhythm`.** A second copy of this fact
   previously drifted: a Part set to DRUM 2 kept browsing melodic voices.
7. **Scope unwinding is ordered.** `open_scopes` records every child/tab/table/popup
   scope; `unwind_scopes` closes them in reverse on the error path. Counting only
   children raises `Missing EndTabBar()` and hides the real error.
8. **Every `ImGui.*` call must pass the arity check.** `scripts/check_imgui_arity.py`
   reads the vendored ReaImGui sources and caught a missing `items_sz` on `Combo`
   that the test fakes accepted.

## Test fakes model real ImGui behaviour

Several bugs above survived because the fakes were too permissive. They now model:
last-item semantics, scope ordering, numeric flag constants (`Flags_*` returned
functions, so any `|` threw), and `(changed, buffer)` returns on text input. Keep the
fakes faithful — a lenient fake is how these shipped.

## Working notes

- Files are **CRLF**. Python edits write LF; normalise after editing or the diff
  explodes.
- Avoid `'\0'` inside bash heredocs — the escape gets eaten and writes a raw NUL,
  turning the file binary. Same for apostrophes inside single-quoted Lua strings.
- The SC-8850 manual PDF is `docs/SC-8850_OM.pdf`. Extracted text is faster to grep;
  see the scratchpad note below. Verify parameter claims against it — a first pass at
  the GM2 category list silently dropped **Pipe** because its heading sat next to a
  page break.

## Open work

**The Settings page (next session's task).** Nothing written yet. Groups A–D are
reached by *separate MIDI ports*, not a SysEx address change, so "which group" means
"which hardware output device". The editor currently derives its device from the
track's `I_MIDIHWOUT`, so the group is already implicit in track routing. Three designs
were on the table when the session ended — ask the user which before building:

1. Map each group to a device in Settings; Part Editor gains a group selector and
   sends to that group's device regardless of track routing.
2. Name-only: label the devices tracks already route to, so the header can say
   "Group B". Routing still follows the track.
3. Full 64-part addressing: channel picker becomes A01–D16, Overview grows to 64 rows.

Also undecided: whether the mapping is global (REAPER `ExtState`, shared with the
Effects Editor) or per project (session state).

Match `editor/effects_editor.lua`'s Settings tab (`tab_settings`, ~line 1667) for
layout and its `cfg` table (~line 52) for storage shape.

**Also outstanding:**

- **Reabank licensing — needs a human decision.** The eight `.reabank` files were
  copied from `docs/` (which `.gitignore` excludes as material "not ours to
  redistribute") into `editor/`, and `index.xml` now ships them via ReaPack. They are
  Roland patch names in an MIT repo. The user was told and said to proceed; flagging
  once more because committing makes it public.
- `part_params.lua` line ~17 cites `docs/research-part-editor-midi-mapping.md`, which
  does not exist. The manual citations beside it do check out.
- Mono/Poly (`40 1x 13`, also CC126/127) and Rx. Channel (`40 1x 02`) exist on the
  8850 and are not implemented.
- Voice names in the Overview come from the reabanks and are live; the `ponytail:`
  comment about hardcoded names is gone.

## Suggested skills

- **`mattpocock-skills:diagnosing-bugs`** — for anything reported broken in the UI.
  Four bugs this session presented as "the button is greyed out" and each had a
  different cause, none of them the obvious one. Reach for it before editing.
- **`caveman:caveman-review`** — one-line severity-tagged review of the diff before
  committing this large a change.
- **`ponytail:ponytail`** — active this session; the Settings page is exactly the kind
  of feature that grows a config system when a table of four device IDs would do.

## User preferences observed

- Wants the manual consulted and cited, not assumed. Corrected a guess about drum-Part
  limits by pointing at it — and was right.
- Prefers being told when a premise is wrong over silent compliance.
- Terse replies. Skip preamble; lead with the answer.
