# Strata Multisample Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Strata, a polyphonic multisample instrument engine for monome norns that maps a folder of rooted samples across the keyboard by nearest-root selection, re-pitches per note, and loops while held with an ADSR.

**Architecture:** Three separated layers — a SuperCollider `CroneEngine` (`lib/Engine_Strata.sc`) owning buffers and voices; a reusable Lua library (`lib/strata.lua`) owning folder scanning, note-name parsing, and the `on/off` API; and a thin demo script (`strata.lua`) owning UI and input. The pure note-name parser is unit-tested on the Mac; the Lua modules are syntax-gated with `luac -p`; the SC engine is verified on hardware via SYSTEM > RESTART.

**Tech Stack:** SuperCollider (CroneEngine), Lua 5.4 (norns API: `engine`, `params`, `poll`, `midi`, `util`, `screen`), `luac`/`lua` for local verification.

---

## File Structure

- `lib/strata.lua` — reusable library. Pure functions `parse_note`, `parse_filename`; instance methods `new`, `on`, `off`, `set`, `load_folder`. No norns globals at load time (so it can be `dofile`'d in tests).
- `lib/Engine_Strata.sc` — the engine. Buffer store, `\strata_voice` SynthDef, voice dict, commands, `amp_out` poll.
- `strata.lua` — demo script. PARAMS menu, MIDI + key input, redraw, default folder load.
- `test/test_strata.lua` — standalone Lua test harness for the pure parser functions.
- `README.md` — install/usage + filename convention.

Tools live at `/opt/homebrew/bin/lua` and `/opt/homebrew/bin/luac`. All commands below run from `~/dev/strata`.

---

### Task 1: Note-name parser (pure, TDD)

**Files:**
- Create: `lib/strata.lua`
- Test: `test/test_strata.lua`

- [ ] **Step 1: Write the failing test**

Create `test/test_strata.lua`:

```lua
-- Run on Mac: lua test/test_strata.lua
local Strata = dofile("lib/strata.lua")

local pass, fail = 0, 0
local function check(desc, got, want)
  if got == want then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format("FAIL %s: got %s want %s", desc, tostring(got), tostring(want)))
  end
end

-- parse_note
check("C4", Strata.parse_note("C4"), 60)
check("A4", Strata.parse_note("A4"), 69)
check("F#2", Strata.parse_note("F#2"), 42)
check("Gb3", Strata.parse_note("Gb3"), 54)
check("C-1 low bound", Strata.parse_note("C-1"), 0)
check("lowercase c4", Strata.parse_note("c4"), 60)
check("raw midi 60", Strata.parse_note("60"), 60)
check("raw out of range", Strata.parse_note("200"), nil)
check("garbage", Strata.parse_note("xyz"), nil)
check("nil input", Strata.parse_note(nil), nil)

-- parse_filename
check("fn note name", Strata.parse_filename("piano_C4.wav"), 60)
check("fn raw midi", Strata.parse_filename("name_60.wav"), 60)
check("fn sharp aif", Strata.parse_filename("inst_F#2.aif"), 42)
check("fn no root", Strata.parse_filename("noroot.wav"), nil)

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/dev/strata && lua test/test_strata.lua`
Expected: FAIL — error like `cannot open lib/strata.lua` (file does not exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `lib/strata.lua` with ONLY the pure functions and module return for now:

```lua
-- strata: multisample instrument library for norns
local Strata = {}
Strata.__index = Strata

local NOTE_OFFSETS = { c = 0, d = 2, e = 4, f = 5, g = 7, a = 9, b = 11 }

-- Parse a note token into a MIDI number (0-127) or nil.
-- Accepts note names ("C4", "F#2", "Gb3", lowercase ok) and raw MIDI ("60").
-- Convention: middle C = C4 = 60, A4 = 69, midi = (octave+1)*12 + semitone.
function Strata.parse_note(token)
  if type(token) == "number" then token = tostring(token) end
  if type(token) ~= "string" then return nil end
  local lower = token:lower()
  local num = tonumber(lower)
  if num ~= nil then
    num = math.floor(num)
    if num >= 0 and num <= 127 then return num end
    return nil
  end
  local letter, acc, oct = lower:match("^([a-g])([#b]?)(%-?%d+)$")
  if letter == nil then return nil end
  local semis = NOTE_OFFSETS[letter]
  if acc == "#" then semis = semis + 1
  elseif acc == "b" then semis = semis - 1 end
  local midi = (tonumber(oct) + 1) * 12 + semis
  if midi < 0 or midi > 127 then return nil end
  return midi
end

-- Extract the root MIDI number from a filename ("piano_C4.wav" -> 60), or nil.
-- Root is the last underscore-separated token before the extension.
function Strata.parse_filename(filename)
  local base = filename:gsub("%.%w+$", "")
  local token = base:match("_([^_]+)$")
  if token == nil then return nil end
  return Strata.parse_note(token)
end

return Strata
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/dev/strata && lua test/test_strata.lua`
Expected: `14 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
cd ~/dev/strata
git add lib/strata.lua test/test_strata.lua
git commit -m "feat: note-name parser for strata library

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: Library instance + on/off/set API

**Files:**
- Modify: `lib/strata.lua` (insert instance methods before `return Strata`)

These methods call norns globals (`engine`) at call time only, so the parser test still passes (it never invokes them).

- [ ] **Step 1: Add instance methods**

In `lib/strata.lua`, insert the following immediately BEFORE the final `return Strata` line:

```lua
-- Create a new instrument instance. Engine holds the audio state;
-- the instance is a thin handle so multiple scripts can share patterns.
function Strata:new()
  local inst = setmetatable({}, Strata)
  return inst
end

-- Set a global engine parameter by name (attack, decay, sustain, release,
-- cutoff, amp, pan). Silently ignores unknown names.
function Strata:set(name, value)
  if engine[name] ~= nil then
    engine[name](value)
  end
end

-- Trigger a note. arg table: {midi=<0-127>, velocity=<0-127, default 100>}.
function Strata:on(note)
  local vel = (note.velocity or 100) / 127
  engine.note_on(note.midi, vel)
end

-- Release a note. arg table: {midi=<0-127>}.
function Strata:off(note)
  engine.note_off(note.midi)
end
```

- [ ] **Step 2: Syntax-check**

Run: `cd ~/dev/strata && luac -p lib/strata.lua && echo OK`
Expected: `OK`

- [ ] **Step 3: Re-run parser tests (ensure no regression)**

Run: `cd ~/dev/strata && lua test/test_strata.lua`
Expected: `14 passed, 0 failed`

- [ ] **Step 4: Commit**

```bash
cd ~/dev/strata
git add lib/strata.lua
git commit -m "feat: strata instance + on/off/set API

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Library load_folder (scan + dispatch to engine)

**Files:**
- Modify: `lib/strata.lua` (insert `load_folder` before `return Strata`)

- [ ] **Step 1: Add load_folder**

In `lib/strata.lua`, insert immediately BEFORE the final `return Strata` line:

```lua
-- Scan a folder, clear the engine, and load every recognised sample.
-- A sample is recognised if it has an audio extension AND its filename
-- ends in a parseable root note (e.g. piano_C4.wav, name_60.wav).
-- Returns the number of zones loaded, or nil + message on failure.
function Strata:load_folder(path)
  if path:sub(-1) ~= "/" then path = path .. "/" end
  local entries = util.scandir(path)
  if entries == nil or #entries == 0 then
    return nil, "no samples in " .. path
  end
  engine.clear()
  local count = 0
  for _, fn in ipairs(entries) do
    local ext = fn:lower()
    if ext:match("%.wav$") or ext:match("%.aif$") or ext:match("%.aiff$") or ext:match("%.flac$") then
      local root = Strata.parse_filename(fn)
      if root ~= nil then
        engine.read(path .. fn, root)
        count = count + 1
      else
        print("strata: skipping (no root note in name): " .. fn)
      end
    end
  end
  if count == 0 then return nil, "no rooted samples in " .. path end
  return count
end
```

- [ ] **Step 2: Syntax-check**

Run: `cd ~/dev/strata && luac -p lib/strata.lua && echo OK`
Expected: `OK`

- [ ] **Step 3: Re-run parser tests**

Run: `cd ~/dev/strata && lua test/test_strata.lua`
Expected: `14 passed, 0 failed`

- [ ] **Step 4: Commit**

```bash
cd ~/dev/strata
git add lib/strata.lua
git commit -m "feat: strata load_folder scan-and-dispatch

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: SuperCollider engine

**Files:**
- Create: `lib/Engine_Strata.sc`

No SC compiler is assumed on the Mac, so verification is on hardware (Step 3). If you happen to have `sclang` installed, an optional class-compile check is noted, but the authoritative check is the device.

- [ ] **Step 1: Write the engine**

Create `lib/Engine_Strata.sc`:

```supercollider
// Strata - multisample instrument engine for norns.
// Loads rooted buffers, selects nearest root per note, re-pitches and loops while held.
Engine_Strata : CroneEngine {
  var <samples;  // List of Events: (buf: Buffer, root: Float)
  var <voices;   // Dictionary: midi note (Integer) -> Synth
  var <params;   // IdentityDictionary of global params

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    samples = List.new;
    voices = Dictionary.new;
    params = IdentityDictionary[
      \attack -> 0.01, \decay -> 0.3, \sustain -> 0.9, \release -> 0.5,
      \cutoff -> 20000, \amp -> 0.7, \pan -> 0.0
    ];

    SynthDef(\strata_voice, {
      arg out, buf, rate = 1, vel = 1, amp = 0.7,
          attack = 0.01, decay = 0.3, sustain = 0.9, release = 0.5,
          cutoff = 20000, pan = 0.0, gate = 1;
      var sig, env;
      env = EnvGen.kr(Env.adsr(attack, decay, sustain, release), gate, doneAction: 2);
      sig = PlayBuf.ar(2, buf, rate * BufRateScale.kr(buf), loop: 1);
      sig = LPF.ar(sig, Lag.kr(cutoff, 0.05));
      sig = sig * env * amp * vel;
      sig = Balance2.ar(sig[0], sig[1], pan);
      Out.ar(out, sig);
    }).add;

    context.server.sync;

    // Load a buffer with its root note.
    this.addCommand(\read, "sf", { arg msg;
      var path = msg[1].asString;
      var root = msg[2];
      Buffer.read(context.server, path, action: { arg buf;
        samples.add((buf: buf, root: root));
      });
    });

    // Free every buffer and stop all voices.
    this.addCommand(\clear, "", { arg msg;
      voices.do { arg syn; syn.set(\gate, 0) };
      voices.clear;
      samples.do { arg s; s[\buf].free };
      samples.clear;
    });

    // Note on: pick nearest-root sample, re-pitch, spawn a voice.
    this.addCommand(\note_on, "if", { arg msg;
      var note = msg[1].asInteger;
      var vel = msg[2];
      var best, bestDist, rate, syn;
      if (samples.size > 0) {
        best = samples[0];
        bestDist = (note - best[\root]).abs;
        samples.do { arg s;
          var d = (note - s[\root]).abs;
          if (d < bestDist) { bestDist = d; best = s; };
        };
        rate = 2 ** ((note - best[\root]) / 12);
        if (voices[note].notNil) { voices[note].set(\gate, 0); };
        syn = Synth(\strata_voice, [
          \out, context.out_b.index, \buf, best[\buf], \rate, rate, \vel, vel,
          \amp, params[\amp], \attack, params[\attack], \decay, params[\decay],
          \sustain, params[\sustain], \release, params[\release],
          \cutoff, params[\cutoff], \pan, params[\pan]
        ], context.xg);
        voices[note] = syn;
        syn.onFree({ if (voices[note] == syn) { voices.removeAt(note) } });
      };
    });

    // Note off: release the voice for this note.
    this.addCommand(\note_off, "i", { arg msg;
      var note = msg[1].asInteger;
      if (voices[note].notNil) {
        voices[note].set(\gate, 0);
        voices.removeAt(note);
      };
    });

    // Release all voices.
    this.addCommand(\all_off, "", { arg msg;
      voices.do { arg syn; syn.set(\gate, 0) };
      voices.clear;
    });

    // Global params applied to new voices.
    [\attack, \decay, \sustain, \release, \cutoff, \amp, \pan].do { arg name;
      this.addCommand(name, "f", { arg msg; params[name] = msg[1]; });
    };

    // Output amplitude poll for UI metering.
    this.addPoll(\amp_out, {
      Amplitude.kr(In.ar(context.out_b.index, 2).sum);
    });
  }

  free {
    voices.do { arg syn; syn.free };
    samples.do { arg s; s[\buf].free };
  }
}
```

- [ ] **Step 2: (Optional) local class-compile check, only if sclang is installed**

Run: `which sclang && echo 'Engine_Strata.postln; 0.exit;' | sclang lib/Engine_Strata.sc 2>&1 | tail -5`
Expected (if sclang present): prints `Engine_Strata` with no compile errors. If `sclang` is absent, skip — the device is the real check.

- [ ] **Step 3: Deploy to a norns and verify it loads**

Copy the project to a norns under `~/dust/code/strata/`, then on the device do **SYSTEM > RESTART** (recompiles SuperCollider). Watch matron/maiden output for SuperCollider errors. Expected: no errors mentioning `Engine_Strata`. (Per the norns workflow this is the user's hardware step — never restart norns-sclang over SSH.)

- [ ] **Step 4: Commit**

```bash
cd ~/dev/strata
git add lib/Engine_Strata.sc
git commit -m "feat: Engine_Strata SuperCollider multisample engine

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: Demo script

**Files:**
- Create: `strata.lua`

- [ ] **Step 1: Write the script**

Create `strata.lua`:

```lua
-- strata
-- multisample instrument
--
-- E1: octave
-- K2/K3: test notes
-- MIDI: play
--
-- samples: dust/audio/strata/
-- named name_C4.wav etc.

engine.name = "Strata"

local Strata = include("strata/lib/strata")

-- all shared state declared up front (locals must precede references)
local inst
local amp_poll
local m
local amp_level = 0
local octave = 0
local n_zones = 0
local status = "loading..."

local DEFAULT_FOLDER = _path.audio .. "strata/"

local function load(folder)
  local count, err = inst:load_folder(folder)
  if count == nil then
    n_zones = 0
    status = tostring(err)
  else
    n_zones = count
    status = "ready"
  end
  redraw()
end

function init()
  inst = Strata:new()

  params:add_separator("strata")
  params:add_control("attack", "attack", controlspec.new(0.001, 5, "exp", 0, 0.01, "s"))
  params:set_action("attack", function(x) inst:set("attack", x) end)
  params:add_control("decay", "decay", controlspec.new(0.001, 5, "exp", 0, 0.3, "s"))
  params:set_action("decay", function(x) inst:set("decay", x) end)
  params:add_control("sustain", "sustain", controlspec.new(0, 1, "lin", 0, 0.9))
  params:set_action("sustain", function(x) inst:set("sustain", x) end)
  params:add_control("release", "release", controlspec.new(0.001, 10, "exp", 0, 0.5, "s"))
  params:set_action("release", function(x) inst:set("release", x) end)
  params:add_control("cutoff", "cutoff", controlspec.new(20, 20000, "exp", 0, 20000, "Hz"))
  params:set_action("cutoff", function(x) inst:set("cutoff", x) end)
  params:add_control("amp", "amp", controlspec.new(0, 1, "lin", 0, 0.7))
  params:set_action("amp", function(x) inst:set("amp", x) end)
  params:add_control("pan", "pan", controlspec.new(-1, 1, "lin", 0, 0))
  params:set_action("pan", function(x) inst:set("pan", x) end)
  params:bang()

  amp_poll = poll.set("amp_out", function(v) amp_level = v end)
  amp_poll.time = 1 / 15
  amp_poll:start()

  load(DEFAULT_FOLDER)

  m = midi.connect()
  m.event = function(data)
    local msg = midi.to_msg(data)
    if msg.type == "note_on" then
      inst:on({ midi = msg.note, velocity = msg.vel })
    elseif msg.type == "note_off" then
      inst:off({ midi = msg.note })
    end
  end
end

function key(n, z)
  local base = 60 + (octave * 12)
  if z == 1 then
    if n == 2 then inst:on({ midi = base, velocity = 100 })
    elseif n == 3 then inst:on({ midi = base + 7, velocity = 100 }) end
  else
    if n == 2 then inst:off({ midi = base })
    elseif n == 3 then inst:off({ midi = base + 7 }) end
  end
end

function enc(n, d)
  if n == 1 then
    octave = util.clamp(octave + d, -3, 3)
    redraw()
  end
end

function redraw()
  screen.clear()
  screen.level(15)
  screen.move(0, 10)
  screen.text("STRATA")
  screen.level(4)
  screen.move(0, 24)
  screen.text("zones: " .. n_zones)
  screen.move(0, 34)
  screen.text("octave: " .. octave)
  screen.move(0, 44)
  screen.text(status)
  screen.level(15)
  screen.rect(0, 59, util.clamp(amp_level, 0, 1) * 127, 4)
  screen.fill()
  screen.update()
end

function cleanup()
  if inst then engine.all_off() end
end
```

- [ ] **Step 2: Syntax-check**

Run: `cd ~/dev/strata && luac -p strata.lua && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd ~/dev/strata
git add strata.lua
git commit -m "feat: strata demo script (params, MIDI, keys, redraw)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: README + final integration check

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the README**

Create `README.md`:

```markdown
# strata

Multisample instrument for monome norns. Drop a folder of rooted samples and play
them polyphonically across the keyboard — nearest-root selection, per-note re-pitch,
loop-while-held with an ADSR.

## install

In maiden: `;install https://github.com/<your-user>/strata`

## samples

Put audio files in `dust/audio/strata/`. Encode the root note in each filename as
the last underscore-separated token before the extension:

- note names: `piano_C4.wav`, `piano_F#3.wav`, `piano_Gb2.aif`
- raw MIDI:   `piano_60.wav`

Convention: middle C = C4 = MIDI 60, A4 = 69. Files without a parseable root are skipped.
Supported extensions: wav, aif, aiff, flac.

## controls

- E1: octave (for the test keys)
- K2 / K3: play test notes (root / fifth)
- MIDI: play
- PARAMS > strata: attack, decay, sustain, release, cutoff, amp, pan

## use as a library

```lua
local Strata = include("strata/lib/strata")
engine.name = "Strata"
local inst = Strata:new()
inst:load_folder(_path.audio .. "strata/ghost_piano/")
inst:on({ midi = 60, velocity = 100 })
inst:off({ midi = 60 })
inst:set("release", 1.2)
```

## development

- Parser tests (Mac): `lua test/test_strata.lua`
- Lua syntax: `luac -p strata.lua lib/strata.lua`
- Engine changes require SYSTEM > RESTART on the device.
```

- [ ] **Step 2: Full syntax + test gate**

Run:
```bash
cd ~/dev/strata && luac -p strata.lua lib/strata.lua && lua test/test_strata.lua
```
Expected: no luac errors, then `14 passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
cd ~/dev/strata
git add README.md
git commit -m "docs: strata README with filename convention and library usage

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Verification Summary

| Layer | How it's verified | When |
|-------|-------------------|------|
| Note parser | `lua test/test_strata.lua` (14 assertions) | Each Lua task |
| Lua modules + script | `luac -p` | Each Lua task |
| SC engine compile | SYSTEM > RESTART, watch for errors | Hardware (user) |
| End-to-end playback | Load a small instrument folder, play keys/MIDI: pitched polyphony, loop while held, clean release | Hardware (user) |

## Self-Review Notes

- **Spec coverage:** filename convention (Task 1, 3), nearest-root mapping + re-pitch (Task 4), loop-while-held + ADSR (Task 4 SynthDef), voice dict + replace-same-note + all_off (Task 4), full command set incl. `read/clear/note_on/note_off/all_off/attack/decay/sustain/release/cutoff/amp/pan` (Task 4), `amp_out` poll (Task 4), library `new/on/off/set/load_folder` (Tasks 2-3), demo script with PARAMS + MIDI + keys + meter (Task 5), README + convention (Task 6). All spec sections mapped.
- **Type consistency:** `parse_note`/`parse_filename` (static, dot-called) vs `new/on/off/set/load_folder` (instance, colon-called) used consistently; `engine.read(path, root)` "sf" matches `Strata:load_folder` dispatch; `engine.note_on(midi, vel 0-1)` "if" matches `Strata:on` scaling velocity/127; param names identical across SynthDef args, engine commands, and PARAMS actions.
- **Out of v1 scope (per spec):** lazy/capped loading, seamless crossfade looper, per-sample loop points, velocity layers, FX send.
```
