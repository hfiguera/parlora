"""Compare source PCM with inserted silence; never infer listening quality from counts."""
import base64, json, math, struct, sys, wave
from pathlib import Path
src = Path(sys.argv[1]); rows = json.loads(src.read_text())
assert not rows['at_bound'], 'Capture bound reached'
frames = rows['frames']; assert frames, 'No generated output was captured'
assert len({r['pid'] for r in frames}) == 1

def level(pcm):
    samples = struct.unpack('<'+'h'*(len(pcm)//2), pcm)
    return {'peak': max(map(abs, samples), default=0),
            'rms': round(math.sqrt(sum(n*n for n in samples)/max(1,len(samples))), 2)}

def wav(name, data):
    with wave.open(str(src.with_name(name)), 'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(24000); f.writeframes(data)

rendered=[]; source=[]; gaps=[]; pending=[]; previous_source=frames[0]['source_bytes']; last_pcm=None
# The recorder arms at the first playout callback, so the capture may omit one initial block.
start=frames[0]['at_us']; byte_cursor=0
for r in frames:
    pcm=base64.b64decode(r['pcm']); rendered.append(pcm)
    is_source=r['source_bytes']>previous_source
    if is_source:
        if pending and last_pcm is not None:
            before=level(last_pcm[-960:]); after=level(pcm[:960])
            gaps.append({'at_ms': round((pending[0]['at_us']-start)/1000,3),
                'inserted_ms': sum(len(base64.b64decode(p['pcm'])) for p in pending)/48,
                'source_position_ms': sum(map(len,source))/48,
                'render_position_ms': (byte_cursor-sum(len(base64.b64decode(p['pcm'])) for p in pending))/48,
                'before': before, 'after': after,
                'signal_on_both_sides': min(before['rms'],after['rms'])>=64})
        pending=[]; source.append(pcm); last_pcm=pcm
    else:
        pending.append(r)
    byte_cursor+=len(pcm); previous_source=r['source_bytes']
# Trailing silence after final source is not counted as an interior gap.
wav('playout.wav', b''.join(rendered)); wav('source.wav', b''.join(source))
summary={'capture':'generated output before CPAL conversion; no microphone recording',
    'frames':len(frames),'source_ms':sum(map(len,source))/48,
    'playout_ms':sum(map(len,rendered))/48,'starvations':max(r['starvations'] for r in frames),
    'interior_gaps':gaps, 'signal_bounded_gaps':sum(g['signal_on_both_sides'] for g in gaps),
    'limits':['first callback may be omitted','signal levels do not establish a clipped syllable or subjective audibility',
              'pre-device output is not physical speaker or browser receiver evidence', 'return tracing adds diagnostic overhead']}
src.with_name('audio-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
