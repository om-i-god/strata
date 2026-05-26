# Strata: Auto-detect Root + Relative Tune

**Date:** 2026-05-26
**Status:** Design approved, pending implementation plan
**Repo/branch:** `~/dev/strata`, branch `auto-detect-root` (off `main`).

## Goal

When a sample is loaded, Strata should **auto-map it to the keyboard** so the right
notes play in tune — by detecting the sample's pitch and setting the root automatically.
Replace the absolute `sample root (Hz)` param with a **relative `tune` (± Hz)** offset for
nudging the mapping.

## Behavior

- **On every sample load:** analyze the sample's pitch; the detected fundamental becomes
  the root, so the key matching that pitch plays the sample untouched and every other key
  is the correct chromatic interval (an "auto-mapped" keyboard).
- **Fallback order:** detection → filename note (e.g. `..._78.wav`) → default **A4 (440 Hz)**
  if the sample is un-pitched (percussion/noise) or detection finds nothing.
- **`tune` (± Hz):** offset added to the detected root. Effective root = `detected_hz + tune`.
  Default 0; range **±200 Hz**; resets to 0 on each new sample load (each sample re-detects
  fresh). Applied gaplessly (no reload).
- Best-effort: pitch tracking is solid on tonal/mono material, may land an **octave off**
  or fail on chords/percussion (→ fallback). User can nudge `tune` by hand.

## Engine (`lib/Engine_Strata.sc`) — pitch analysis + in-place root

New class ivars: `analyzer` (the analysis Synth or nil), `pitchBus` (a control Bus).

1. **Allocate the bus** in `alloc`: `pitchBus = Bus.control(context.server, 1);`
2. **`set_root` command** `"f"` — update the most-recently-loaded sample's root in place
   (no reload), so note-on rate uses the new root:
   ```supercollider
   this.addCommand(\set_root, "f", { arg msg;
     if (samples.size > 0) { samples[samples.size - 1][\root] = msg[1]; };
   });
   ```
3. **`detect` command** `""` — analyze the most-recent buffer's pitch into `pitchBus`,
   self-freeing after ~1.2 s. Free any prior analyzer first.
   ```supercollider
   this.addCommand(\detect, "", { arg msg;
     if (samples.size > 0) {
       var b = samples[samples.size - 1][\buf];
       if (analyzer.notNil) { analyzer.free; analyzer = nil; };
       analyzer = {
         var sig = PlayBuf.ar(2, b, BufRateScale.kr(b), loop: 1).sum;
         var freq, hasFreq;
         # freq, hasFreq = Pitch.kr(sig, initFreq: 220, minFreq: 40, maxFreq: 4000,
             ampThreshold: 0.02, median: 7);
         Out.kr(pitchBus.index, freq * (hasFreq > 0));
         EnvGen.kr(Env.new([0, 0], [1.2]), doneAction: 2); // free synth after 1.2s
       }.play(target: context.xg);
     }
   });
   ```
4. **`detected_hz` poll** — report the bus to Lua:
   ```supercollider
   this.addPoll(\detected_hz, { In.kr(pitchBus) });
   ```
5. **`clear` command** also frees the analyzer (it may be reading a buffer about to be
   freed): add `if (analyzer.notNil) { analyzer.free; analyzer = nil; };` to `clear`.
6. **`free`** cleanup: `if (analyzer.notNil) { analyzer.free }; pitchBus.free;`

Engine change → **SYSTEM > RESTART on White** to take effect.

## Script (`strata.lua`)

Remove the `sample_root_hz` param and its action. Add:

- State: `local detected_hz = 440`, `local detected_latest = 0`.
- Poll handler:
  ```lua
  detect_poll = poll.set("detected_hz", function(v) detected_latest = v end)
  detect_poll.time = 1 / 10
  detect_poll:start()
  ```
- `tune` param (replaces sample root):
  ```lua
  params:add_control("tune", "tune", controlspec.new(-200, 200, "lin", 0, 0, "Hz"))
  params:set_action("tune", function() apply_root() end)
  ```
- Apply helper (gapless):
  ```lua
  local function apply_root()
    if single_sample_path then
      engine.set_root(Strata.hz_to_midi(detected_hz + params:get("tune")))
    end
  end
  ```
- `sample` action: provisional root from filename (else 440), reset tune, load, kick off
  detection, then after the analysis window apply the detected root (or keep provisional):
  ```lua
  params:set_action("sample", function(file)
    local lf = type(file) == "string" and file:lower() or ""
    if not (lf:match("%.wav$") or lf:match("%.aif$")
         or lf:match("%.aiff$") or lf:match("%.flac$")) then return end
    single_sample_path = file
    inst_name = file:match("[^/]+$") or file
    local note = Strata.parse_filename(inst_name)
    detected_hz = note and Strata.midi_to_hz(note) or 440
    params:set("tune", 0, true)                 -- fresh sample => no manual offset
    inst:load_sample(file, Strata.hz_to_midi(detected_hz))  -- provisional, instantly playable
    status = "detecting..."
    redraw()
    engine.detect()
    clock.run(function()
      clock.sleep(1.3)                          -- analysis window (engine frees at ~1.2s)
      if detected_latest > 20 and detected_latest < 8000 then
        detected_hz = detected_latest
        status = "root ~" .. math.floor(detected_hz) .. " hz"
      else
        status = "ready"                        -- kept provisional (filename / 440)
      end
      apply_root()
      redraw()
    end)
  end)
  ```
- `redraw`: show effective root = `detected_hz + params:get("tune")`:
  ```lua
  screen.text("root: " .. math.floor(detected_hz + params:get("tune")) .. " hz")
  ```

`apply_root`, `detected_hz`, `detected_latest`, `single_sample_path` declared with the
other top-level locals (before any function references them).

## Why `set_root` instead of reload

Today changing the root reloads the whole sample (`engine.clear` + `engine.read`), causing
a gap. `set_root` updates the stored root in place; new note-ons use it immediately. Both
detection and the `tune` knob use it → gapless retuning.

## No loops / recursion

`tune` action → `set_root` (no reload, no detect). Detection result → `apply_root` →
`set_root` (no reload, no detect). The provisional `load_sample` is the only `clear`+`read`,
and it happens once per file selection. `clear` frees the analyzer to avoid analyzing a
freed buffer.

## Error handling / edge cases

- **Un-pitched / detection fails:** `detected_latest` stays ~0 → keep provisional root
  (filename note, else 440). No crash.
- **Octave error:** possible; user nudges `tune` (note: ±200 Hz won't cover a full octave at
  high pitches — acceptable; they can also re-pick or rename). Documented limitation.
- **Detect with no sample loaded:** command guards on `samples.size > 0`.
- **Rapid re-loads:** each `detect` frees the prior analyzer; `clear` frees it too.
- **Poll value when idle:** `pitchBus` holds the last value; Lua only samples it inside the
  post-load window via the clock, so stale values don't mis-set the root.

## Testing

- **Syntax:** `luac -p strata.lua lib/strata.lua`; existing unit tests (`hz_to_midi`/
  `midi_to_hz`, 23) still pass.
- **Engine:** no local sclang — static review of the `.sc` (Pitch/Bus/poll correctness),
  then SYSTEM > RESTART on White; confirm `detect`/`set_root` commands and `detected_hz`
  poll register.
- **Hardware playtest (user):** load the kurzweil sample → confirm it auto-maps in tune
  (play a known interval); load an arbitrary tonal sample → root tracks; turn `tune` →
  gapless sharp/flat nudge; load a percussive sample → falls back without crashing.

## Non-goals

- Polyphonic / chord pitch detection (monophonic estimate only).
- Octave-error correction heuristics.
- Persisting `tune` across sample loads (it resets per load by design).
- Multisample auto-mapping across zones (single-sample model only).
