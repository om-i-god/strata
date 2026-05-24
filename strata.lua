-- strata
-- multisample instrument
--
-- E1: octave  E2: instrument
-- K2/K3: test notes
-- MIDI: play
--
-- samples: dust/audio/strata/<inst>/
-- named name_C4.wav (or name_60.wav)

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
local instruments = {}
local inst_name = ""

local ROOT_DIR = _path.audio .. "strata/"

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

-- find instrument subfolders under dust/audio/strata/ (util.scandir
-- appends "/" to directories).
local function scan_instruments()
  instruments = {}
  local entries = util.scandir(ROOT_DIR)
  if entries then
    for _, e in ipairs(entries) do
      if e:sub(-1) == "/" then table.insert(instruments, e:sub(1, -2)) end
    end
  end
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

  scan_instruments()
  if #instruments > 0 then
    params:add_option("instrument", "instrument", instruments, 1)
    params:set_action("instrument", function(i)
      inst_name = instruments[i]
      load(ROOT_DIR .. inst_name .. "/")
    end)
  end
  params:bang()

  amp_poll = poll.set("amp_out", function(v) amp_level = v end)
  amp_poll.time = 1 / 15
  amp_poll:start()

  -- no subfolders: fall back to loading the top-level folder directly
  if #instruments == 0 then load(ROOT_DIR) end

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
  elseif n == 2 then
    if #instruments > 0 then params:delta("instrument", d) end
  end
end

function redraw()
  screen.clear()
  screen.level(15)
  screen.move(0, 10)
  screen.text("STRATA")
  screen.level(4)
  screen.move(0, 20)
  screen.text(inst_name ~= "" and inst_name or "(top-level)")
  screen.move(0, 30)
  screen.text("zones: " .. n_zones)
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
  if inst then engine.all_off() end
end
