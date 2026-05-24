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
