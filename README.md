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

    local Strata = include("strata/lib/strata")
    engine.name = "Strata"
    local inst = Strata:new()
    inst:load_folder(_path.audio .. "strata/ghost_piano/")
    inst:on({ midi = 60, velocity = 100 })
    inst:off({ midi = 60 })
    inst:set("release", 1.2)

## development

- Parser tests (Mac): `lua test/test_strata.lua`
- Lua syntax: `luac -p strata.lua lib/strata.lua`
- Engine changes require SYSTEM > RESTART on the device.

## known limitations (v1)

- Whole-buffer loop while held; the loop seam may click on non-looping material.
  A seamless dual-buffer crossfade looper is a planned follow-up.
- The whole sample folder is loaded eagerly; large libraries would need lazy/capped
  loading (a planned follow-up).
- The `amp_out` meter reads the engine output bus and may lag by one control block.
- `clear()` frees buffers immediately; voices still releasing at that moment cut off.
