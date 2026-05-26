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
check("G9 upper bound", Strata.parse_note("G9"), 127)
check("G#9 over range", Strata.parse_note("G#9"), nil)
check("non-integer raw", Strata.parse_note("60.5"), nil)
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
