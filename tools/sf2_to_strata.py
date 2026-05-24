#!/usr/bin/env python3
"""sf2_to_strata.py — extract SoundFont presets into Strata sample folders.

Reads a .sf2 directly (RIFF parser, no deps beyond stdlib), resolves each named
preset -> instrument -> sampled zones, pulls each recorded sample at its true
root key, merges stereo L/R pairs (duplicates mono to stereo for Strata's
2-channel voice SynthDef), and writes 16-bit WAVs named <preset>_<midiroot>.wav
into OUTROOT/<preset>/.

Usage:
    python3 sf2_to_strata.py FONT.sf2 OUTDIR "Preset Name" ["Another Preset" ...]
    # list presets first by editing or see tools notes; preset names are exact.

Caveat: Strata v1 loops the whole buffer while held and ignores SoundFont loop
points/envelopes. Short wavetable-style samples (e.g. piano) will drone rather
than decay; long phrase/pad samples (choir, strings) sound great.
"""
import struct, os, sys, wave, array

SF2 = sys.argv[1]
OUTROOT = sys.argv[2]
WANT = sys.argv[3:]  # preset names to extract

data = open(SF2,'rb').read()

def chunks(buf, off, end):
    out=[]
    while off < end-8:
        cid=buf[off:off+4]; sz=struct.unpack('<I',buf[off+4:off+8])[0]
        out.append((cid,off+8,sz)); off+=8+sz+(sz&1)
    return out

top = chunks(data,12,8+struct.unpack('<I',data[4:8])[0])
pdta=sdta=None
for cid,off,sz in top:
    if cid==b'LIST':
        lt=data[off:off+4]
        if lt==b'pdta': pdta=(off+4,off+sz)
        elif lt==b'sdta': sdta=(off+4,off+sz)
def subs(rng):
    d={}
    for cid,off,sz in chunks(data,rng[0],rng[1]): d[cid]=(off,sz)
    return d
pd=subs(pdta); sd=subs(sdta)
smpl_off,smpl_sz = sd[b'smpl']   # 16-bit PCM block

def recs(tag,size):
    off,sz=pd[tag]; return off, sz//size
# phdr
poff,pn = recs(b'phdr',38)
phdr=[]
for i in range(pn):
    r=data[poff+i*38:poff+i*38+38]
    name=r[0:20].split(b'\x00')[0].decode('latin1','replace').strip()
    preset,bank,bag=struct.unpack('<HHH',r[20:26])
    phdr.append((name,preset,bank,bag))
# pbag
boff,bn=recs(b'pbag',4)
pbag=[struct.unpack('<HH',data[boff+i*4:boff+i*4+4]) for i in range(bn)]
# pgen
goff,gn=recs(b'pgen',4)
pgen=[(struct.unpack('<H',data[goff+i*4:goff+i*4+2])[0], data[goff+i*4+2:goff+i*4+4]) for i in range(gn)]
# inst
ioff,inn=recs(b'inst',22)
inst=[]
for i in range(inn):
    r=data[ioff+i*22:ioff+i*22+22]
    name=r[0:20].split(b'\x00')[0].decode('latin1','replace').strip()
    bag=struct.unpack('<H',r[20:22])[0]
    inst.append((name,bag))
# ibag
iboff,ibn=recs(b'ibag',4)
ibag=[struct.unpack('<HH',data[iboff+i*4:iboff+i*4+4]) for i in range(ibn)]
# igen
igoff,ign=recs(b'igen',4)
igen=[(struct.unpack('<H',data[igoff+i*4:igoff+i*4+2])[0], data[igoff+i*4+2:igoff+i*4+4]) for i in range(ign)]
# shdr
shoff,shn=recs(b'shdr',46)
shdr=[]
for i in range(shn):
    r=data[shoff+i*46:shoff+i*46+46]
    nm=r[0:20].split(b'\x00')[0].decode('latin1','replace').strip()
    start,end,sl,el,sr=struct.unpack('<IIIII',r[20:40])
    pitch,corr,link,stype=struct.unpack('<BbHH',r[40:46])
    shdr.append(dict(name=nm,start=start,end=end,sr=sr,pitch=pitch,link=link,stype=stype))

GEN_INSTRUMENT=41; GEN_KEYRANGE=43; GEN_VELRANGE=44; GEN_SAMPLEID=53; GEN_ROOTKEY=58
def word(b): return struct.unpack('<H',b)[0]
def sshort(b): return struct.unpack('<h',b)[0]

def preset_instruments(pi):
    """instrument indices referenced by preset pi"""
    res=[]
    g0=phdr[pi][3]; g1=phdr[pi+1][3]
    for b in range(g0,g1):
        gs,ge=pbag[b][0], pbag[b+1][0]
        for k in range(gs,ge):
            op,amt=pgen[k]
            if op==GEN_INSTRUMENT: res.append(word(amt))
    return res

def instrument_zones(ii):
    """list of zones: dict(sampleID, rootkey_override, velhi)"""
    zones=[]; gdef={}
    b0=inst[ii][1]; b1=inst[ii+1][1]
    for b in range(b0,b1):
        gs,ge=ibag[b][0], ibag[b+1][0]
        z=dict(gdef)  # inherit globals
        sid=None
        for k in range(gs,ge):
            op,amt=igen[k]
            if op==GEN_SAMPLEID: sid=word(amt)
            elif op==GEN_ROOTKEY: z['root']=sshort(amt)
            elif op==GEN_VELRANGE: z['velhi']=amt[1]
            elif op==GEN_KEYRANGE: z['klo']=amt[0]; z['khi']=amt[1]
        if sid is None:
            gdef=z  # global zone sets defaults
        else:
            z['sid']=sid; zones.append(z)
    return zones

def read_mono(sh):
    b=data[smpl_off+sh['start']*2 : smpl_off+sh['end']*2]
    a=array.array('h'); a.frombytes(b); return a

def write_wav(path, left, right, sr):
    st=array.array('h')
    n=min(len(left),len(right))
    for i in range(n): st.append(left[i]); st.append(right[i])
    wf=wave.open(path,'wb'); wf.setnchannels(2); wf.setsampwidth(2); wf.setframerate(sr)
    wf.writeframes(st.tobytes()); wf.close()

def sanitize(s):
    return ''.join(c.lower() if c.isalnum() else '_' for c in s).strip('_').replace('__','_')

# map preset name -> index
name2pi={}
for i in range(pn-1): name2pi.setdefault(phdr[i][0], i)

total=0
for want in WANT:
    if want not in name2pi:
        print(f"!! preset not found: {want}"); continue
    pi=name2pi[want]
    instr_ids=preset_instruments(pi)
    prefix=sanitize(want)
    outdir=os.path.join(OUTROOT, prefix)
    os.makedirs(outdir, exist_ok=True)
    # gather best zone per root
    best={}   # root -> (velhi, zone)
    for ii in instr_ids:
        for z in instrument_zones(ii):
            sh=shdr[z['sid']]
            root = z.get('root',-1)
            if root<0 or root>127: root=sh['pitch']
            velhi=z.get('velhi',127)
            if root not in best or velhi>best[root][0]:
                best[root]=(velhi,z)
    written=0
    for root,(velhi,z) in sorted(best.items()):
        sh=shdr[z['sid']]
        sr=sh['sr']
        if sh['stype'] in (2,4) and sh['link']<len(shdr):  # right=2/left=4 stereo pair
            partner=shdr[sh['link']]
            a=read_mono(sh); b=read_mono(partner)
            if sh['stype']==4: left,right=a,b   # this is left
            else: left,right=b,a                # this is right
        else:
            m=read_mono(sh); left=right=m
        if len(left)<8: continue
        write_wav(os.path.join(outdir, f"{prefix}_{root}.wav"), left, right, sr)
        written+=1
    print(f"{want:24s} -> {prefix}/  ({written} samples, roots {min(best)}–{max(best)})")
    total+=written
print(f"\nTOTAL {total} wav files under {OUTROOT}")
