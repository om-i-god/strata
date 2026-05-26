# Strata Improvements: Single-Sample Mode + Loop Toggle

**Date:** 2026-05-26
**Status:** Design approved, pending implementation plan
**Repo/branch:** `~/dev/strata`, branch `strata-improvements` (off `osc-input`, so the
OSC receiver already deployed to White is preserved).

## Goal

Two improvements to the Strata norns sampler:
1. **Single-sample mode** — pick one sample file from disk and play it instantly across
   the keyboard, with its base pitch set as a frequency in Hz.
2. **Loop toggle** — let the user choose one-shot (play through once) vs loop-while-held,
   defaulting to **one-shot**.

## Part 1 — Single-sample mode (host-side only, no engine change)

### Library additions (`lib/strata.lua`)
Pure helpers (unit-testable on the Mac) plus one loader, mirroring `load_folder`:

```lua
-- A4 = 440 Hz = MIDI 69. Fractional results are fine (engine root is a float).
function Strata.hz_to_midi(hz)
  return 69 + 12 * math.log(hz / 440, 2)
end

function Strata.midi_to_hz(midi)
  return 440 * 2 ^ ((midi - 69) / 12)
end

-- Load a single sample as the whole instrument, re-pitched from root_midi.
function Strata:load_sample(path, root_midi)
  engine.clear()
  engine.read(path, root_midi)
end
```

The engine already accepts a fractional MIDI root via `engine.read(path, root)` ("sf"),
and re-pitches with `rate = 2^((note - root)/12)`, so a Hz-derived fractional root works
with no engine change.

### Script changes (`strata.lua`)
- **PARAMS `sample`** — `params:add_file("sample", "sample", _path.audio)`. Selecting a
  file calls the loader and it is instantly playable. The file browser also reaches any
  folder on disk (bonus "load from anywhere").
- **PARAMS `sample_root_hz`** — a frequency control, default **440**:
  `params:add_control("sample_root_hz", "sample root", controlspec.new(20, 8000, "exp", 0, 440, "Hz"))`.
  Its action: if a single sample is currently loaded, reload it at the new root
  (`inst:load_sample(single_sample_path, Strata.hz_to_midi(hz))`).
- **On file select:** ignore empty/`"cancel"` paths. If the filename carries a note
  (`Strata.parse_filename`), pre-fill `sample_root_hz` from it via
  `params:set("sample_root_hz", Strata.midi_to_hz(note), true)` — the `silent` flag
  avoids a double-load. Then `inst:load_sample(path, Strata.hz_to_midi(params:get("sample_root_hz")))`,
  set `single_sample_path = path`, and update status to the basename.
- **Coexistence:** selecting an instrument *folder* sets `single_sample_path = nil` (back
  to multisample); selecting a *file* sets it. Last action wins.
- **`redraw`:** when `single_sample_path` is set, show the sample basename + its root Hz;
  otherwise show the folder/instrument name (current behavior).

### New state (declared with the other top-level locals)
```lua
local single_sample_path = nil
```

## Part 2 — Loop toggle (engine change)

### Engine (`lib/Engine_Strata.sc`)
- Add a `loop = 0` arg to the `\strata_voice` SynthDef and use it:
  `PlayBuf.ar(2, buf, rate * BufRateScale.kr(buf), loop: loop)`.
  With `loop = 0` the sample plays through once then outputs silence; the existing ADSR
  (`gate`/`doneAction: 2`) still shapes amplitude and frees the synth on release.
- Add `\loop -> 0` to the `params` IdentityDictionary (default one-shot).
- Add `\loop` to the global-param command loop so a `loop` command is registered (format
  `"f"`, value 0/1).
- Pass `\loop, params[\loop]` in the `Synth(\strata_voice, [...])` arg array in `note_on`.

Loop applies to **new** voices (like the other global params), consistent with the
existing design.

### Script (`strata.lua`)
- **PARAMS `loop`** — `params:add_option("loop", "loop", {"off","on"}, 1)` (default off),
  action `inst:set("loop", v == 2 and 1 or 0)`. `Strata:set` already forwards to
  `engine.loop`.

### Deployment consequence
Editing the `.sc` requires **SYSTEM > RESTART** on White to recompile the engine (per the
norns workflow; never restart norns-sclang over SSH). Part 1 (Lua only) just needs a
script reload.

## Error handling / edge cases

- **Empty/cancelled file selection:** the `sample` action ignores `""`, `"cancel"`, and
  non-existent paths (no load, no crash).
- **`sample_root_hz` change with no single sample loaded:** action is a no-op (guarded on
  `single_sample_path`).
- **Filename with no note token:** `parse_filename` returns nil → keep `sample_root_hz` at
  its current value (440 by default).
- **Double-load avoidance:** pre-filling `sample_root_hz` during a file load uses
  `params:set(..., true)` (silent) so the root action does not fire a second load.
- **Loop param before engine ready:** `inst:set("loop", …)` is a no-op if `engine.loop`
  isn't registered yet (guarded by `Strata:set`'s `engine[name] ~= nil` check).

## Testing

- **Unit (Mac, `test/test_strata.lua`):** extend with
  `hz_to_midi(440) == 69`, `hz_to_midi(261.625…) ≈ 60`, `midi_to_hz(69) == 440`,
  `midi_to_hz(60) ≈ 261.63` (float tolerance, e.g. abs diff < 0.01).
- **Syntax:** `luac -p strata.lua lib/strata.lua`.
- **Engine:** loads without error after SYSTEM > RESTART (hardware).
- **Hardware playtest (deferred to user):** pick a single sample → instantly plays across
  keys; set `sample root (Hz)` and confirm pitch reference shifts; toggle `loop` and
  confirm one-shot vs sustained; confirm switching back to a folder restores multisample.

## Non-goals (this round)

- Mapping multiple individual files to different keys (single sample replaces the set).
- Auto-audition / preview note on select (user chose instantly-playable).
- Fixing the `amp_out` meter (reads 0 even when sounding — separate cosmetic bug).
- Anything on the OSC bridge (paused mid-debug, separate work).
