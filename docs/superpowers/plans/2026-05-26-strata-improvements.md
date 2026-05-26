# Strata Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add single-sample mode (pick one file from disk, instantly playable, root set in Hz) and a loop on/off toggle (default one-shot) to the Strata norns sampler.

**Architecture:** Single-sample mode is host-side only — pure Hz↔MIDI helpers + a `load_sample` loader in `lib/strata.lua`, wired to a file-browser param + Hz root param in `strata.lua`; the engine already accepts a fractional MIDI root. The loop toggle adds a `loop` arg to the `\strata_voice` SynthDef plus a `loop` engine command/param.

**Tech Stack:** norns Lua (`params`, `osc`, `util`, `controlspec`, `_path`), SuperCollider (CroneEngine), `lua`/`luac` (`/opt/homebrew/bin`). Branch `strata-improvements` in `~/dev/strata` (off `osc-input`). Deploy to White (192.168.1.99) via `~/.ssh/norns`.

**Verification reality:** Pure helpers are unit-tested (`lua test/test_strata.lua`). Lua files are `luac -p` gated. The engine `.sc` has no local compiler — verified on White via SYSTEM > RESTART (hardware step).

---

## File Structure

- `lib/strata.lua` — add `Strata.hz_to_midi`, `Strata.midi_to_hz` (pure), `Strata:load_sample` (loader). 
- `test/test_strata.lua` — add Hz↔MIDI assertions.
- `lib/Engine_Strata.sc` — add `loop` arg/param/command (4 edits).
- `strata.lua` — add `single_sample_path` state; `sample`, `sample_root_hz`, `loop` params; clear single-sample on folder select; show root Hz in `redraw`.

---

### Task 1: Hz↔MIDI helpers + load_sample (TDD)

**Files:**
- Modify: `lib/strata.lua`
- Test: `test/test_strata.lua`

- [ ] **Step 1: Add failing tests**

In `test/test_strata.lua`, find the final block:

```lua
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
```

Replace it with:

```lua
local function approx(desc, got, want, tol)
  tol = tol or 0.01
  if type(got) == "number" and math.abs(got - want) <= tol then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL %s: got %s want ~%s", desc, tostring(got), tostring(want)))
  end
end

approx("hz_to_midi 440", Strata.hz_to_midi(440), 69)
approx("hz_to_midi 261.6256", Strata.hz_to_midi(261.6256), 60)
approx("hz_to_midi 880", Strata.hz_to_midi(880), 81)
approx("midi_to_hz 69", Strata.midi_to_hz(69), 440)
approx("midi_to_hz 60", Strata.midi_to_hz(60), 261.63, 0.1)
approx("roundtrip 53.7hz", Strata.hz_to_midi(Strata.midi_to_hz(Strata.hz_to_midi(53.7))), Strata.hz_to_midi(53.7))

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/dev/strata && lua test/test_strata.lua`
Expected: FAIL — `attempt to call a nil value (field 'hz_to_midi')` (helpers not defined yet).

- [ ] **Step 3: Add the helpers and loader**

In `lib/strata.lua`, find the final line `return Strata` and insert the following immediately BEFORE it:

```lua
-- A4 = 440 Hz = MIDI 69. Result may be fractional (engine root is a float).
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

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/dev/strata && lua test/test_strata.lua`
Expected: `23 passed, 0 failed` (17 existing + 6 new).

- [ ] **Step 5: Syntax-check**

Run: `cd ~/dev/strata && luac -p lib/strata.lua && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
cd ~/dev/strata
git add lib/strata.lua test/test_strata.lua
git commit -m "feat: hz_to_midi/midi_to_hz helpers + load_sample loader

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: Loop toggle in the engine

**Files:**
- Modify: `lib/Engine_Strata.sc` (4 edits)

No local sclang — verified on hardware in Task 4. Apply each edit; each `find` string occurs exactly once.

- [ ] **Step 1: Add the `loop` SynthDef arg**

Find:
```supercollider
          cutoff = 20000, pan = 0.0, gate = 1;
```
Replace with:
```supercollider
          cutoff = 20000, pan = 0.0, loop = 0, gate = 1;
```

- [ ] **Step 2: Use it in PlayBuf**

Find:
```supercollider
      sig = PlayBuf.ar(2, buf, rate * BufRateScale.kr(buf), loop: 1);
```
Replace with:
```supercollider
      sig = PlayBuf.ar(2, buf, rate * BufRateScale.kr(buf), loop: loop);
```

- [ ] **Step 3: Add `\loop` to the param store**

Find:
```supercollider
      \cutoff -> 20000, \amp -> 0.7, \pan -> 0.0
    ];
```
Replace with:
```supercollider
      \cutoff -> 20000, \amp -> 0.7, \pan -> 0.0, \loop -> 0
    ];
```

- [ ] **Step 4: Register the `loop` command**

Find:
```supercollider
    [\attack, \decay, \sustain, \release, \cutoff, \amp, \pan].do { arg name;
```
Replace with:
```supercollider
    [\attack, \decay, \sustain, \release, \cutoff, \amp, \pan, \loop].do { arg name;
```

- [ ] **Step 5: Pass `loop` at voice spawn**

Find:
```supercollider
          \cutoff, params[\cutoff], \pan, params[\pan]
        ], context.xg);
```
Replace with:
```supercollider
          \cutoff, params[\cutoff], \pan, params[\pan], \loop, params[\loop]
        ], context.xg);
```

- [ ] **Step 6: Visual balance check + commit**

Read the file and confirm braces/parens still balance and the five edits are present. (No `luac` for `.sc`.)

```bash
cd ~/dev/strata
git add lib/Engine_Strata.sc
git commit -m "feat: loop on/off (PlayBuf loop arg + loop command/param, default one-shot)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Script params, wiring, and redraw

**Files:**
- Modify: `strata.lua`

- [ ] **Step 1: Add `single_sample_path` state**

Find:
```lua
local midi_devices = {}
```
Replace with:
```lua
local midi_devices = {}
local single_sample_path = nil
```

- [ ] **Step 2: Add loop + single-sample params (after the pan control, before scan_instruments)**

Find:
```lua
  params:add_control("pan", "pan", controlspec.new(-1, 1, "lin", 0, 0))
  params:set_action("pan", function(x) inst:set("pan", x) end)

  scan_instruments()
```
Replace with:
```lua
  params:add_control("pan", "pan", controlspec.new(-1, 1, "lin", 0, 0))
  params:set_action("pan", function(x) inst:set("pan", x) end)

  -- loop on/off (one-shot vs loop-while-held)
  params:add_option("loop", "loop", { "off", "on" }, 1)
  params:set_action("loop", function(v) inst:set("loop", v == 2 and 1 or 0) end)

  -- single-sample mode: root frequency, then the file picker
  params:add_control("sample_root_hz", "sample root",
    controlspec.new(20, 8000, "exp", 0, 440, "Hz"))
  params:set_action("sample_root_hz", function(hz)
    if single_sample_path then
      inst:load_sample(single_sample_path, Strata.hz_to_midi(hz))
    end
  end)
  params:add_file("sample", "sample", _path.audio)
  params:set_action("sample", function(file)
    local lf = type(file) == "string" and file:lower() or ""
    if not (lf:match("%.wav$") or lf:match("%.aif$")
         or lf:match("%.aiff$") or lf:match("%.flac$")) then return end
    single_sample_path = file
    n_zones = 1
    inst_name = file:match("[^/]+$") or file
    local note = Strata.parse_filename(inst_name)
    if note then params:set("sample_root_hz", Strata.midi_to_hz(note), true) end
    inst:load_sample(file, Strata.hz_to_midi(params:get("sample_root_hz")))
    status = "ready"
    redraw()
  end)

  scan_instruments()
```

- [ ] **Step 3: Clear single-sample mode when a folder is picked**

Find:
```lua
    params:set_action("instrument", function(i)
      inst_name = instruments[i]
      load(ROOT_DIR .. inst_name .. "/")
    end)
```
Replace with:
```lua
    params:set_action("instrument", function(i)
      inst_name = instruments[i]
      single_sample_path = nil
      load(ROOT_DIR .. inst_name .. "/")
    end)
```

- [ ] **Step 4: Show the root Hz in redraw when in single-sample mode**

Find:
```lua
  screen.move(0, 40)
  screen.text("octave: " .. octave)
```
Replace with:
```lua
  screen.move(0, 40)
  if single_sample_path then
    screen.text("root: " .. math.floor(params:get("sample_root_hz")) .. " hz")
  else
    screen.text("octave: " .. octave)
  end
```

- [ ] **Step 5: Syntax-check**

Run: `cd ~/dev/strata && luac -p strata.lua && echo OK`
Expected: `OK`

- [ ] **Step 6: Re-run unit tests (no regression)**

Run: `cd ~/dev/strata && lua test/test_strata.lua`
Expected: `23 passed, 0 failed`

- [ ] **Step 7: Commit**

```bash
cd ~/dev/strata
git add strata.lua
git commit -m "feat: single-sample file picker + Hz root + loop param + redraw

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: Deploy and verify on White

**Files:** deploy `strata.lua`, `lib/strata.lua`, `lib/Engine_Strata.sc` to White.

- [ ] **Step 1: Final local gate**

Run:
```bash
cd ~/dev/strata && luac -p strata.lua lib/strata.lua && lua test/test_strata.lua
```
Expected: no luac errors, then `23 passed, 0 failed`.

- [ ] **Step 2: Deploy to White**

```bash
rsync -a -e "ssh -i ~/.ssh/norns" ~/dev/strata/strata.lua ~/dev/strata/lib/ we@192.168.1.99:/home/we/dust/code/strata/
```
(Deploys the script and the `lib/` dir incl. the new `Engine_Strata.sc`.)

- [ ] **Step 3: Engine recompile (USER, on the device)**

The `.sc` engine changed, so on White: **SYSTEM > RESTART**, then load the **strata** script. (Never restart norns-sclang over SSH — it breaks jack.) Watch maiden for any `Engine_Strata` compile error. Expected: loads clean, engine command list now includes `loop`.

- [ ] **Step 4: Verify `loop` command registered (controller, after restart)**

Run: `python3 /tmp/norns_repl.py 'engine.list_commands()'` (or reload the script and watch the printed engine command list).
Expected: `loop` appears with format `f` alongside `attack/amp/...`.

- [ ] **Step 5: Hardware playtest (USER)**

- PARAMS → `sample`: browse `dust/audio/` and pick a single `.wav` → confirm it plays across keys immediately (K2/K3 or MIDI).
- PARAMS → `sample root`: change the Hz → confirm the pitch reference shifts (same key now sounds higher/lower).
- PARAMS → `loop`: toggle on/off → confirm one-shot (plays through once) vs loop-while-held.
- PARAMS → `instrument`: pick a folder → confirm it returns to multisample (screen shows folder name, not a single file).

---

## Self-Review Notes

- **Spec coverage:** `hz_to_midi`/`midi_to_hz`/`load_sample` (Task 1); `sample` file picker + instantly-playable (Task 3 Step 2); `sample_root_hz` default 440 + live reload + filename pre-fill via silent `params:set` (Task 3 Step 2); coexistence/last-wins via `single_sample_path` cleared on folder select (Task 3 Step 3) and set on file select (Step 2); redraw shows root Hz (Step 4); loop arg/param/command + spawn (Task 2); loop param default off (Task 3 Step 2); deploy + restart consequence (Task 4 Step 3); unit tests (Task 1). All spec sections mapped.
- **Edge cases in code:** file action rejects non-audio paths (incl. the `_path.audio` directory default fired on `params:bang`); `sample_root_hz` action guarded on `single_sample_path`; filename pre-fill uses silent set to avoid double-load; `inst:set("loop",…)` no-ops if `engine.loop` unregistered.
- **Type/name consistency:** `single_sample_path`, `sample_root_hz`, `sample`, `loop` used identically across tasks; `Strata.hz_to_midi`/`midi_to_hz` (dot, pure) vs `Strata:load_sample` (colon, instance) match Task 1 definitions; engine `\loop` param/arg/command names consistent across the five Task 2 edits.
- **Out of scope (per spec):** per-key multi-file mapping, auto-audition, amp_out meter fix, OSC bridge.
```
