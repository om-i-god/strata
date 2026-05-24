# Strata — Multisample Engine for norns

**Date:** 2026-05-24
**Status:** Design approved, pending implementation plan

## Summary

Strata is a polyphonic, sample-based instrument engine for monome norns. It plays
**true multisamples**: a folder of recordings, each tagged with a root note, mapped
across the keyboard by **nearest-root selection** and re-pitched per played note.
Held notes **loop while held** and are shaped by an ADSR envelope.

It is built as our own `CroneEngine` (not a wrapper around an existing one), with
[mx.samples](https://infinitedigits.co/mxsamples/) by Zack Scholl / infinite digits
as the technique reference — specifically its nearest-root sample selection and lazy
loading ideas. Strata ships independent code.

## Non-goals (v1)

- Lazy / capped background loading (mx.samples caps at 200 samples). v1 loads a single
  instrument folder eagerly. Lazy loading is a documented future step.
- Seamless loop crossfades. v1 uses whole-buffer `loop:1`; a dual-buffer equal-power
  crossfade looper is a documented future option.
- Per-sample loop points authored in metadata. v1 loops the whole buffer.
- Velocity layering (multiple samples per note at different velocities). Future.

## Architecture

Three cleanly separated pieces:

```
strata.lua             -- demo script: UI, MIDI + grid/key input, folder selection
lib/strata.lua         -- reusable library: folder scan, note-name parsing, on/off API
lib/Engine_Strata.sc   -- SuperCollider engine: buffer store, voice synths, playback
```

Making the library its own module (mirroring mx.samples' `include()` pattern) lets other
scripts depend on Strata later and keeps the demo script thin. Each layer has one job:

- **`lib/Engine_Strata.sc`** — owns audio: buffers, SynthDefs, voice allocation, params.
  Knows nothing about folders or filenames.
- **`lib/strata.lua`** — owns the host-side instrument abstraction: scans a folder, parses
  note names to MIDI numbers, sends `read`/`clear`/`note_on`/`note_off`. Knows nothing
  about UI.
- **`strata.lua`** — owns presentation and input. Depends on `lib/strata.lua`.

## Sample loading & mapping

### Filename convention
Samples live in one folder. The root note is encoded in the filename suffix:

- Note-name form: `name_C3.wav`, `name_F#4.wav`, `name_Gb2.wav`
- Raw MIDI form:  `name_60.wav`

`lib/strata.lua` scans the folder, parses each filename's trailing token into a MIDI
number (note-name parser supports `A`–`G`, `#`/`b`, octave `-1`..`9`, middle C = C4 = MIDI 60,
A4 = 69 — the standard MIDI / scientific-pitch convention, `midi = (octave+1)*12 + semitone`).
Files that don't parse are skipped with a warning.

### Load protocol (Lua → SC)
1. `engine.clear()` — free all buffers, reset the store.
2. For each parsed file: `engine.read(path, rootMidi)`.

SC reads each buffer asynchronously (`Buffer.read`) and appends `(buf, root)` to its store.

### Mapping = nearest root
At note-on, the engine selects the buffer whose root is **closest** to the played note
(ties resolve to the lower root) and re-pitches it:

```
rate = (2 ** ((note - root) / 12)) * BufRateScale.kr(buf)
```

This is genuinely multisample, needs no split-point bookkeeping, and degrades gracefully
when only some roots are present (even a single sample works — it just stretches further).

## Voice & playback (SuperCollider)

### SynthDef `\strata_voice`
Signal path:

```
PlayBuf.ar(2, buf, rate, loop: 1)
  -> * Env.adsr(attack, decay, sustain, release).kr(gate, doneAction: 2)
  -> * amp * velocity
  -> LPF lowpass at `cutoff`
  -> Pan2 / balance at `pan`
  -> Out.ar(out)
```

- **Loop while held:** `loop: 1` loops the whole buffer. Note-off lowers the gate, the
  release tail plays, then `doneAction: 2` frees the synth.
- Args: `out, buf, rate, amp, velocity, attack, decay, sustain, release, cutoff, pan, gate`.
- `rate` and `cutoff` are `.lag`'d to avoid zipper noise.

### Voice management
- A dict keyed by MIDI note → Synth node.
- `note_on(num, vel)`: if `num` is already sounding, release the old voice first, then
  spawn a new one and store it.
- `note_off(num)`: set that voice's `gate` to 0 (release), remove from the dict.
- `all_off()`: gate-off every active voice.
- Polyphony is bounded naturally by held keys; no hard cap in v1.

## Commands exposed to Lua

| Command    | Format | Effect                                          |
|------------|--------|-------------------------------------------------|
| `read`     | `"sf"` | Load buffer at path (string) with root (float MIDI) |
| `clear`    | `""`   | Free all buffers, reset store                   |
| `note_on`  | `"if"` | num (int), velocity 0–1 (float)                 |
| `note_off` | `"i"`  | num (int) — release that voice                  |
| `all_off`  | `""`   | Release all voices                              |
| `attack`   | `"f"`  | ADSR attack (s)                                 |
| `decay`    | `"f"`  | ADSR decay (s)                                  |
| `sustain`  | `"f"`  | ADSR sustain level (0–1)                        |
| `release`  | `"f"`  | ADSR release (s)                                |
| `cutoff`   | `"f"`  | Lowpass cutoff (Hz)                             |
| `amp`      | `"f"`  | Master amp (0–1)                                |
| `pan`      | `"f"`  | Stereo pan (-1..1)                              |

Global params (`attack`…`pan`) are stored engine-side and applied to **new** voices; the
ADSR/cutoff/pan args are passed at synth spawn.

One poll for UI metering: `amp_out` — `Amplitude.kr` of the output bus.

## Library API (`lib/strata.lua`)

Mirrors mx.samples' embeddable shape:

```lua
strata = include("strata/lib/strata")
engine.name = "Strata"
inst = strata:new()
inst:load_folder(_path.audio .. "strata/ghost_piano/")  -- scan + clear + read all
inst:on({midi = 60, velocity = 100})                    -- velocity 0–127, scaled to 0–1
inst:off({midi = 60})
inst:set("attack", 0.01)                                -- forwards to engine.attack etc.
```

`load_folder` does: `engine.clear()`, scan dir, parse note names, `engine.read(path, root)`
per file, and return a count of loaded zones (or nil + message on failure).

## Demo script (`strata.lua`)

- `init()`: `engine.name = "Strata"`, create `inst`, load a default folder if present,
  set up the `amp_out` poll, register params (folder, attack, decay, sustain, release,
  cutoff, amp, pan) in the norns PARAMS menu.
- MIDI input → `inst:on/off`. Norns keys K2/K3 trigger test notes; E1 transposes.
- `redraw()`: show instrument name, loaded-zone count, active-voice count, amp meter.

## Error handling

- Filename that doesn't parse to a note: skip, print a warning, continue.
- Empty / missing folder: `load_folder` returns nil + message; script shows "no samples".
- `note_on` before any buffer is loaded: engine ignores (no store entry) — no crash.
- Buffer still loading when played: nearest-root selection naturally falls back to whatever
  roots have finished loading; if none, the note is silently dropped.

## Testing

- **SC compile gate:** engine must load without errors after SYSTEM > RESTART.
- **Lua syntax gate:** `luac -p` on `strata.lua` and `lib/strata.lua`.
- **Note-name parser:** unit-test the parser (`C4 -> 60`, `A4 -> 69`, `F#2 -> 42`,
  `C-1 -> 0`, raw `60 -> 60`, garbage `-> nil`) in a small standalone Lua harness on the Mac.
- **Hardware playtest:** load a small instrument folder on a norns, confirm pitched
  polyphonic playback, looping while held, and clean release. (Deferred to user per the
  norns playtest workflow.)

## Workflow notes (norns-specific)

- Changes to `Engine_Strata.sc` require **SYSTEM > RESTART** on the device — not just a
  script reload. Never restart norns-sclang over SSH (breaks jack).
- Project lives at `~/dev/strata`; deploy to a norns under `~/dust/code/strata/`.

## Future steps (out of v1 scope)

1. Lazy / capped background loading for large libraries.
2. Seamless dual-`PlayBuf` equal-power crossfade looper for sustained material.
3. Per-sample loop-point metadata.
4. Velocity layers (multiple samples per note).
5. Effects send (delay/reverb) and tilt EQ, matching the Yarn/Swelter family.
