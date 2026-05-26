# Strata Auto-detect Root + Tune Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On every sample load, detect the sample's pitch and auto-map it to the keyboard; replace the absolute `sample root (Hz)` param with a relative `tune` (± Hz) offset.

**Architecture:** The engine gains a `detect` command (a transient `Pitch.kr` analysis synth writing the fundamental to a control bus), a `detected_hz` poll, and a `set_root` command that updates the loaded sample's root in place (gapless). The script loads with a provisional root (filename note → 440), kicks off detection, and after a ~1.3 s window applies the detected root (or keeps provisional); `tune` adds a ± Hz offset, both applied via `set_root`.

**Tech Stack:** SuperCollider (CroneEngine: Pitch, Bus, PlayBuf, poll), norns Lua (params, poll, clock), `luac`. Branch `auto-detect-root` in `~/dev/strata`. Deploy to White (192.168.1.133), `~/.ssh/norns`.

**Verification:** No new pure-Lua logic (existing `hz_to_midi`/`midi_to_hz` tests cover the math). Lua gated with `luac -p` + the 23 existing tests. The `.sc` has no local compiler → static review + SYSTEM > RESTART on White + playtest.

---

### Task 1: Engine — pitch detection, poll, in-place root

**Files:**
- Modify: `lib/Engine_Strata.sc` (5 edits; each `find` occurs once)

- [ ] **Edit 1: class ivars**

Find:
```supercollider
  var <params;   // IdentityDictionary of global params
```
Replace with:
```supercollider
  var <params;   // IdentityDictionary of global params
  var <analyzer; // transient pitch-analysis Synth (or nil)
  var <pitchBus; // control Bus holding the detected fundamental (Hz)
```

- [ ] **Edit 2: allocate the control bus**

Find:
```supercollider
      \cutoff -> 20000, \amp -> 0.7, \pan -> 0.0, \loop -> 0
    ];

    SynthDef(\strata_voice, {
```
Replace with:
```supercollider
      \cutoff -> 20000, \amp -> 0.7, \pan -> 0.0, \loop -> 0
    ];
    pitchBus = Bus.control(context.server, 1);

    SynthDef(\strata_voice, {
```

- [ ] **Edit 3: free analyzer in clear (it may read a buffer about to be freed)**

Find:
```supercollider
    this.addCommand(\clear, "", { arg msg;
      voices.do { arg syn; syn.set(\gate, 0) };
```
Replace with:
```supercollider
    this.addCommand(\clear, "", { arg msg;
      if (analyzer.notNil) { analyzer.free; analyzer = nil; };
      voices.do { arg syn; syn.set(\gate, 0) };
```

- [ ] **Edit 4: add set_root + detect commands and the detected_hz poll**

Find:
```supercollider
    // Global params applied to new voices.
    [\attack, \decay, \sustain, \release, \cutoff, \amp, \pan, \loop].do { arg name;
      this.addCommand(name, "f", { arg msg; params[name] = msg[1]; });
    };

    // Output amplitude poll for UI metering.
```
Replace with:
```supercollider
    // Global params applied to new voices.
    [\attack, \decay, \sustain, \release, \cutoff, \amp, \pan, \loop].do { arg name;
      this.addCommand(name, "f", { arg msg; params[name] = msg[1]; });
    };

    // Update the loaded sample's root (MIDI, may be fractional) in place.
    this.addCommand(\set_root, "f", { arg msg;
      if (samples.size > 0) { samples[samples.size - 1][\root] = msg[1]; };
    });

    // Analyze the most-recent buffer's pitch into pitchBus; self-frees ~1.2s.
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
          EnvGen.kr(Env.new([0, 0], [1.2]), doneAction: 2);
        }.play(target: context.xg);
      };
    });

    // Poll: detected fundamental (Hz); 0 when unvoiced/idle.
    this.addPoll(\detected_hz, { In.kr(pitchBus) });

    // Output amplitude poll for UI metering.
```

- [ ] **Edit 5: free cleanup**

Find:
```supercollider
  free {
    voices.do { arg syn; syn.free };
    samples.do { arg s; s[\buf].free };
  }
```
Replace with:
```supercollider
  free {
    if (analyzer.notNil) { analyzer.free };
    voices.do { arg syn; syn.free };
    samples.do { arg s; s[\buf].free };
    pitchBus.free;
  }
```

- [ ] **Edit 6: delimiter balance check + commit**

Run a brace/paren/bracket balance check (no local sclang):
```bash
cd ~/dev/strata && python3 -c "s=open('lib/Engine_Strata.sc').read()
for o,c in [('{','}'),('(',')'),('[',']')]:
 print(o,c,s.count(o),s.count(c),'OK' if s.count(o)==s.count(c) else 'MISMATCH')"
```
Expected: all OK. Then:
```bash
cd ~/dev/strata
git add lib/Engine_Strata.sc
git commit -m "feat: pitch detect (Pitch.kr) + detected_hz poll + in-place set_root

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: Script — tune param + detection flow

**Files:**
- Modify: `strata.lua` (5 edits)

- [ ] **Edit 1: state for detection**

Find:
```lua
local single_sample_path = nil
local held = {}
```
Replace with:
```lua
local single_sample_path = nil
local held = {}
local detected_hz = 440   -- current root reference (Hz): detection / filename / default
local detected_latest = 0 -- latest value from the detected_hz poll
local detect_poll
```

- [ ] **Edit 2: apply_root helper (gapless), before init**

Find:
```lua
-- (re)bind the MIDI handler to the chosen vport, detaching the previous one.
local function setup_midi(port)
  if m then m.event = nil end
  m = midi.connect(port)
  m.event = midi_event
end
```
Replace with:
```lua
-- (re)bind the MIDI handler to the chosen vport, detaching the previous one.
local function setup_midi(port)
  if m then m.event = nil end
  m = midi.connect(port)
  m.event = midi_event
end

-- apply the effective root (detected + tune) to the engine, gaplessly.
local function apply_root()
  if single_sample_path then
    engine.set_root(Strata.hz_to_midi(detected_hz + params:get("tune")))
  end
end
```

- [ ] **Edit 3: replace sample-root param + sample action with tune + detection**

Find:
```lua
  -- single-sample mode: root frequency, then the file picker
  params:add_control("sample_root_hz", "sample root",
    controlspec.new(20, 8000, "exp", 0, 440, "Hz"))
  params:set_action("sample_root_hz", function(hz)
    if single_sample_path then
      inst:load_sample(single_sample_path, Strata.hz_to_midi(hz))
    end
  end)
  params:add_file("sample", "sample", DEFAULT_SAMPLE)
  params:set_action("sample", function(file)
    local lf = type(file) == "string" and file:lower() or ""
    if not (lf:match("%.wav$") or lf:match("%.aif$")
         or lf:match("%.aiff$") or lf:match("%.flac$")) then return end
    single_sample_path = file
    inst_name = file:match("[^/]+$") or file
    local note = Strata.parse_filename(inst_name)
    if note then params:set("sample_root_hz", Strata.midi_to_hz(note), true) end
    inst:load_sample(file, Strata.hz_to_midi(params:get("sample_root_hz")))
    status = "ready"
    redraw()
  end)
```
Replace with:
```lua
  -- single-sample mode: relative tune (Hz), then the file picker
  params:add_control("tune", "tune", controlspec.new(-200, 200, "lin", 0, 0, "Hz"))
  params:set_action("tune", function() apply_root() end)
  params:add_file("sample", "sample", DEFAULT_SAMPLE)
  params:set_action("sample", function(file)
    local lf = type(file) == "string" and file:lower() or ""
    if not (lf:match("%.wav$") or lf:match("%.aif$")
         or lf:match("%.aiff$") or lf:match("%.flac$")) then return end
    single_sample_path = file
    inst_name = file:match("[^/]+$") or file
    -- provisional root: filename note if present, else A4 (440)
    local note = Strata.parse_filename(inst_name)
    detected_hz = note and Strata.midi_to_hz(note) or 440
    params:set("tune", 0, true)  -- fresh sample: clear any manual offset
    inst:load_sample(file, Strata.hz_to_midi(detected_hz))
    status = "detecting..."
    redraw()
    engine.detect()
    clock.run(function()
      clock.sleep(1.3)  -- analysis window (engine analyzer self-frees ~1.2s)
      if detected_latest > 20 and detected_latest < 8000 then
        detected_hz = detected_latest
        status = "root ~" .. math.floor(detected_hz) .. " hz"
      else
        status = "ready"  -- kept provisional (filename / 440)
      end
      apply_root()
      redraw()
    end)
  end)
```

- [ ] **Edit 4: start the detected_hz poll in init**

Find:
```lua
  amp_poll = poll.set("amp_out", function(v) amp_level = v end)
  amp_poll.time = 1 / 15
  amp_poll:start()
end
```
Replace with:
```lua
  amp_poll = poll.set("amp_out", function(v) amp_level = v end)
  amp_poll.time = 1 / 15
  amp_poll:start()

  detect_poll = poll.set("detected_hz", function(v) detected_latest = v end)
  detect_poll.time = 1 / 10
  detect_poll:start()
end
```

- [ ] **Edit 5: redraw shows effective root (detected + tune)**

Find:
```lua
  screen.text("root: " .. math.floor(params:get("sample_root_hz")) .. " hz")
```
Replace with:
```lua
  screen.text("root: " .. math.floor(detected_hz + params:get("tune")) .. " hz")
```

- [ ] **Step 6: gate + commit**

Run: `cd ~/dev/strata && luac -p strata.lua && echo OK && lua test/test_strata.lua | tail -1`
Expected: `OK` then `23 passed, 0 failed`.
Also confirm no leftover `sample_root_hz`: `grep -n sample_root_hz strata.lua || echo "none"` → `none`.
```bash
cd ~/dev/strata
git add strata.lua
git commit -m "feat: auto-detect root on load + relative tune (replaces sample root Hz)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Review, deploy, verify on White

- [ ] **Step 1: Static SuperCollider review (no local compiler)**

Dispatch a review of the `.sc` change: confirm `Pitch.kr` arg names/order, `Bus.control`/`.index`/`.free`, `{...}.play(target:)` synth + `EnvGen` doneAction self-free, `Out.kr(pitchBus.index, ...)`, the `analyzer` free paths (detect/clear/free), and `addPoll(\detected_hz, { In.kr(pitchBus) })`. Address any Critical/Important findings before deploying.

- [ ] **Step 2: Final local gate**

Run: `cd ~/dev/strata && luac -p strata.lua lib/strata.lua && lua test/test_strata.lua | tail -1`
Expected: no luac errors, `23 passed, 0 failed`.

- [ ] **Step 3: Deploy to White (correct destinations)**

```bash
rsync -a -e "ssh -i ~/.ssh/norns" ~/dev/strata/lib/ we@192.168.1.133:/home/we/dust/code/strata/lib/
rsync -a -e "ssh -i ~/.ssh/norns" ~/dev/strata/strata.lua we@192.168.1.133:/home/we/dust/code/strata/strata.lua
ssh -i ~/.ssh/norns we@192.168.1.133 'grep -c "detect" /home/we/dust/code/strata/lib/Engine_Strata.sc'
```
(Note `lib/` → `.../strata/lib/` explicitly — the earlier deploy bug was a missing `lib/` on the destination.)

- [ ] **Step 4: Engine recompile (USER, on the device)**

On White: **SYSTEM > RESTART**, then load **strata**. Watch maiden for `Engine_Strata` errors (none expected). After restart, confirm the new commands registered: `python3 /tmp/norns_repl.py 'engine.list_commands()'` (NORNS_HOST=192.168.1.133) should list `detect` and `set_root`.

- [ ] **Step 5: Hardware playtest (USER)**

- Load the kurzweil sample (default) → after ~1.3 s the screen shows `root ~NNN hz`; play an interval and confirm it's in tune / auto-mapped.
- Load a different tonal sample → root tracks it.
- Turn `tune` → gapless sharp/flat nudge of the whole keyboard.
- Load a percussive/noisy sample → no crash, falls back (status `ready`, provisional root).

---

## Self-Review Notes

- **Spec coverage:** auto-detect on load (Task 2 Edit 3 `engine.detect()` + clock window; Task 1 Edit 4 `detect`/`detected_hz`); auto-map via root (Task 1 `set_root`, Task 2 `apply_root`); fallback detect→filename→440 (Task 2 Edit 3 provisional + post-window keep); `tune` ±200 Hz replacing absolute root, reset on load (Task 2 Edits 1/3); gapless `set_root` (Task 1 Edit 4, Task 2 `apply_root`/tune action); analyzer freed on clear/detect/free (Task 1 Edits 3/4/5); redraw effective root (Task 2 Edit 5); poll wired (Task 2 Edit 4). All spec sections mapped.
- **No reload loops:** `tune`→`apply_root`→`set_root` (no reload/detect); detection result→`apply_root`→`set_root`; only the file selection does `load_sample` (clear+read) once; `clear` frees the analyzer.
- **Type/name consistency:** engine commands `detect`/`set_root` and poll `detected_hz` named identically in Task 1 (define) and Task 2 (call/subscribe). `detected_hz`/`detected_latest`/`apply_root`/`single_sample_path` consistent. `tune` param id consistent across action, sample reset, redraw.
- **Out of scope (per spec):** polyphonic detection, octave-error correction, persisting tune across loads, multisample auto-map.
```
