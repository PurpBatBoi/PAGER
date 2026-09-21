# Handoff — Drum Controls factory data

Written for: the next agent picking up this work.

Repo: `C:\Users\purps\Documents\STUFF-DEV\PAGER`, branch `Rework`.
Last commit: `643e94d` "Wip3". **There are uncommitted changes** (see below).

## What this work is

Plan 001 (`plans/001-implement-drum-controls.md`) added a Drum Controls tab to
the Part Editor: nine per-note parameters on two shared drum maps, DT1 SysEx at
`41 mp rr`. That plan is **DONE and committed** in `643e94d`; `plans/README.md`
records it.

Everything since has been about the *factory default values* the panel seeds
each note from — which plan 001 explicitly deferred as a STOP condition, and
which the operator then asked for.

## Current state

**Committed** (`643e94d`): the whole of plan 001, plus a first version of the
factory-data extraction.

**Uncommitted** — one fix, described below:

```
M editor/drum_defaults.lua          regenerated, 9 columns not 7
M editor/drum_params.lua            comment only
M scripts/extract_drum_defaults.py  the actual fix + fixtures
M tests/test_drum_defaults.lua      fixtures + derived column indices
D scripts/scrape_gsae_drums.py      dead end, deleted (see below)
```

### The fix

`docs/gsae-decomp/NOTES.md` (P2) documents the `.def` drum record as 28 bytes
with 12 per-note parameter bytes at +16, and says **"exact field order still
TBD"**. The first extraction mapped 7 of those 12 and guessed:

- claimed **Delay** was absent from the source table — it is **idx 8**
- claimed **Chorus** was "always 0" — that is true only of the SC-8850 map;
  idx 5 is non-zero throughout SC-55/88/88Pro

Both are now extracted. The resolved order is all nine parameters in GSAE's own
Drum Window column order — see the module docstring in
`scripts/extract_drum_defaults.py`, which documents the order and the three
independent checks it is held against.

Regenerate with:

```
python scripts/extract_drum_defaults.py
```

### Verification status

| Kit | Verified against | Rows |
|---|---|---|
| SC-55 STANDARD (LSB 1, pc 0) | GSAE Drum Window screenshot | 18 × 9 cols |
| SC-55 ROOM (LSB 1, pc 8) | GSAE Drum Window screenshot | 9 × 9 cols |
| SC-8850 STANDARD 1 (LSB 4, pc 0) | Sound Canvas VA panel | 2 notes |
| other 86 kits | same tables, same extraction path | unverified |

Both window fixtures are duplicated deliberately: in the extractor (so a bad
regeneration fails the build) and in `tests/test_drum_defaults.lua` (so it
fails the suite). Test column indices are looked up from `DD.FIELDS` rather
than hardcoded — the column order is the thing under test, so a literal index
would silently follow a regeneration that moved it.

Total data: 4 maps, 89 kits, 7857 notes. A kit is `(Bank LSB, program change)`,
never a program change alone.

## What is NOT verified, and would be worth doing next

1. **A kit from a map other than SC-55.** The two window fixtures are both
   LSB 1, so they confirm the per-kit lookup but not the Bank-LSB keying. An
   SC-88Pro or SC-8850 kit screenshot would close that. This is the single
   highest-value next check.
2. **Live hardware.** The operator confirmed SC-8850 note 22 in the actual Part
   Editor against the VA panel (Pitch 12 / Level 107 / rest 0), but only that
   one note, and only on the 8850 map.

## Dead ends — do not repeat these

- **Reading GSAE's grid via UI automation.** `TGSAEGrid` is a custom-painted
  Delphi grid: `DefaultDrawing = False`, a `GRIDDrawCell` handler, no stored
  cell text. `LVM_*` messages return 0, it has no child windows, and UI
  Automation exposes only two scrollbars. pywinauto cannot read it either.
  `scripts/scrape_gsae_drums.py` was written for this and is deleted in the
  working tree; it is still in `643e94d` if wanted (it does work on ordinary
  `SysListView32` grids — it read REAPER's 6830-row Actions list).
- **Capturing GSAE's MIDI output.** `File > Save as SYSX` and `Comm > Send all`
  both transmit only parameters the user has **modified**, not full state — an
  11-byte file and two `40 1x 15` Part writes respectively. Drum note setup is
  never in it. The operator identified this before the agent did.
- **`.ga4` files** are GSAE's native project format, not SysEx. 74 bytes of
  Part parameters.

`scripts/capture_sysex.py` is kept and works — it polls winmm buffers (a
ctypes callback does **not** fire reliably on winmm's thread; that cost a
debugging cycle) and decodes `41 mp rr` live. Verified end to end on a
loopMIDI port. Useful if hardware verification is wanted later: the operator
has a real SC-8850 on ports A–D plus a loopMIDI port named `GSAE`.

## Verification commands

```
python scripts/extract_drum_defaults.py      # regenerate + self-check
C:/Lua54/lua54.exe tests/test_drum_defaults.lua
python scripts/run_checks.py                 # full gate
```

Expected: **127 `ok:` lines**. `run_checks.py` exits non-zero because of one
pre-existing failure — `self-test needs docs/[native]16-chs-baseline.mid` —
which is accepted by plan 001 and predates this work (confirmed by stashing).
No other failure is acceptable.

A useful end-to-end check, not currently in the suite: seed every note of every
kit and encode it, and the wire byte must equal the stored factory byte.
Last run: **0 mismatches of 70,713 values**.

## Conventions worth knowing

- Lua sources are **CRLF**. New files must be converted or the diff is
  whole-file. `git diff --check` must stay clean.
- `editor/drum_defaults.lua` is **generated** — never hand-edit it.
- Pitch is stored relative to a neutral **60**, not centred on 64. Canonical
  range is therefore `-60..+67`, asymmetric on purpose. `drum_params.lua`
  subtracts the neutral on the way in; `drum_messages.lua` adds it back.
- Pan is `0 = Random`, `1..64..127 = L..C..R`, canonical `-64..+63`.
- `tests/harness.lua` lifts named functions out of `part_editor.lua` by regex,
  so **renaming a lifted function breaks the tests loudly** — that is by
  design, not a bug to work around.

## Suggested skills

- **`mattpocock-skills:code-review`** — review the uncommitted diff against
  plan 001's Done criteria before committing. The plan has an explicit
  reviewer checklist at its end (exact address bytes, the Pan offset, the
  shared-vs-Part state boundary, passive restore).
- **`ponytail:ponytail-review`** — only if the extractor grows further. It is
  already at the edge of what a data-extraction script should carry.

Do **not** reach for a subagent to re-derive the column order; it is settled and
documented in the extractor docstring with its evidence.

## One open question for the operator

`docs/gsae-decomp/NOTES.md` still says the drum field order is "TBD". It is now
resolved. Whether to update that file is the operator's call — it is their
reverse-engineering notebook, and this work did not touch it.
