-- strata
-- sample instrument
--
-- E1: octave   K2/K3: test notes   MIDI: play
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

local ROOT_DIR = _path.audio .. "strata/"
local DEFAULT_SAMPLE = ROOT_DIR .. "kurzweil_strings/kurzweil_strings_78.wav"

-- incoming MIDI: filtered by the selected channel ("all" or 1-16).
-- note_on with velocity 0 is treated as note_off (running-status convention).
local function midi_event(data)
  local msg = midi.to_msg(data)
  local ch = params:get("midi_channel") -- 1 = all, n>1 = channel (n-1)
  if ch > 1 and msg.ch ~= (ch - 1) then return end
  if msg.type == "note_on" and msg.vel > 0 then
    inst:on({ midi = msg.note, velocity = msg.vel })
  elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
    inst:off({ midi = msg.note })
  end
end

-- (re)bind the MIDI handler to the chosen vport, detaching the previous one.
local function setup_midi(port)
  if m then m.event = nil end
  m = midi.connect(port)
  m.event = midi_event
end

function init()
  inst = Strata:new()

  -- OSC input: notes pushed from another norns/script over the network
  -- /strata/noteon {note,vel(1-127)}  /strata/noteoff {note}  /strata/alloff
  osc.event = function(path, args)
    if path == "/strata/noteon" then
      inst:on({ midi = args[1], velocity = args[2] })
    elseif path == "/strata/noteoff" then
      inst:off({ midi = args[1] })
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
  screen.move(0, 20)
  screen.text(inst_name ~= "" and inst_name or "(no sample)")
  screen.move(0, 30)
  screen.text("root: " .. math.floor(params:get("sample_root_hz")) .. " hz")
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
