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
