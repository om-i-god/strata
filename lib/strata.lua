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
    if num ~= math.floor(num) then return nil end  -- reject non-integer raw MIDI
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

return Strata
