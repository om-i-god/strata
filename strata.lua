-- strata
-- sample instrument
--
-- E1: octave (transposes everything)   MIDI / OSC: play
--
-- PARAMS > sample: pick any .wav (the instrument is the selected sample)
-- default: dust/audio/strata/kurzweil_strings/kurzweil_strings_78.wav

engine.name = "Strata"

local Strata = include("strata/lib/strata")

-- all shared state declared up front (locals must precede references)
local inst
local amp_poll
local m
local amp_level = 0
local octave = 0
local status = "loading..."
local inst_name = ""
local midi_devices = {}
local single_sample_path = nil
local held = {}
local detected_hz = 440   -- current root reference (Hz): detection / filename / default
local detected_latest = 0 -- latest value from the detected_hz poll
local detect_poll

local ROOT_DIR = _path.audio .. "strata/"
local DEFAULT_SAMPLE = ROOT_DIR .. "kurzweil_strings/kurzweil_strings_78.wav"

-- note in/out, transposed by `octave` (all sources). held[] remembers the
-- transposed note per incoming note, so note-off still matches if octave
-- changed mid-hold (avoids stuck notes).
local function note_on(note, vel)
  local t = util.clamp(note + octave * 12, 0, 127)
  held[note] = t
  inst:on({ midi = t, velocity = vel })
end

local function note_off(note)
  local t = held[note] or util.clamp(note + octave * 12, 0, 127)
  held[note] = nil
  inst:off({ midi = t })
end

-- incoming MIDI: filtered by the selected channel ("all" or 1-16).
-- note_on with velocity 0 is treated as note_off (running-status convention).
local function midi_event(data)
  local msg = midi.to_msg(data)
  local ch = params:get("midi_channel") -- 1 = all, n>1 = channel (n-1)
  if ch > 1 and msg.ch ~= (ch - 1) then return end
  if msg.type == "note_on" and msg.vel > 0 then
    note_on(msg.note, msg.vel)
  elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
    note_off(msg.note)
  end
end

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

function init()
  inst = Strata:new()

  -- OSC input: notes pushed from another norns/script over the network
  -- /strata/noteon {note,vel(1-127)}  /strata/noteoff {note}  /strata/alloff
  osc.event = function(path, args)
    if path == "/strata/noteon" then
      note_on(args[1], args[2])
    elseif path == "/strata/noteoff" then
      note_off(args[1])
    elseif path == "/strata/alloff" then
      engine.all_off()
    end
  end

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

  -- loop on/off (one-shot vs loop-while-held)
  params:add_option("loop", "loop", { "off", "on" }, 1)
  params:set_action("loop", function(v) inst:set("loop", v == 2 and 1 or 0) end)

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

  -- MIDI input selection
  params:add_separator("midi in")
  local channels = { "all" }
  for i = 1, 16 do channels[i + 1] = tostring(i) end
  params:add_option("midi_channel", "midi channel", channels, 1)
  for i = 1, #midi.vports do
    midi_devices[i] = i .. ": " .. (midi.vports[i].name or "----")
  end
  params:add_option("midi_device", "midi device", midi_devices, 1)
  params:set_action("midi_device", function(i) setup_midi(i) end)

  params:bang()

  amp_poll = poll.set("amp_out", function(v) amp_level = v end)
  amp_poll.time = 1 / 15
  amp_poll:start()

  detect_poll = poll.set("detected_hz", function(v) detected_latest = v end)
  detect_poll.time = 1 / 10
  detect_poll:start()
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
  screen.move(0, 20)
  screen.text(inst_name ~= "" and inst_name or "(no sample)")
  screen.move(0, 30)
  screen.text("root: " .. math.floor(detected_hz + params:get("tune")) .. " hz")
  screen.move(0, 40)
  screen.text("octave: " .. octave)
  screen.move(0, 50)
  screen.text(status)
  screen.level(15)
  screen.rect(0, 59, util.clamp(amp_level, 0, 1) * 127, 4)
  screen.fill()
  screen.update()
end

function cleanup()
  osc.event = nil
  if inst then engine.all_off() end
end
