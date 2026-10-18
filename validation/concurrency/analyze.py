"""Tone identity and gaps at a decoded boundary; not speech intelligibility."""
import argparse, json, math
from array import array
from pathlib import Path
import sys


def analyze(path, rate, expected, alternatives):
    raw=array('h',Path(path).read_bytes())
    if sys.byteorder!='little': raw.byteswap()
    window=rate//50  # Nonoverlapping 20 ms identity observations.
    rows=[]
    for start in range(0,len(raw)-window+1,window):
        block=raw[start:start+window]
        rms=math.sqrt(sum(v*v for v in block)/window)
        power={}
        for freq in alternatives:
            coefficient=2*math.cos(2*math.pi*freq/rate)
            a=b=0
            for value in block:
                current=value+coefficient*a-b;b=a;a=current
            power[freq]=max(0,a*a+b*b-coefficient*a*b)/(window*window)
        winner=max(power,key=power.get)
        rows.append({'ms':start*1000/rate,'rms':rms,'winner':winner,
            'foreign_fraction':2*max((v for k,v in power.items() if k!=expected),default=0)/max(1,rms*rms),
            'expected_power':power[expected],'foreign_ratio':max((v for k,v in power.items() if k!=expected),default=0)/max(1,power[expected])})
    signal=[i for i,r in enumerate(rows) if r['rms']>=150 and r['winner']==expected]
    if not signal: return {'passed':False,'reason':'No expected signal','duration_ms':len(raw)*1000/rate}
    # Remove one second at each end for initial negotiation and intentional close.
    first=signal[0]+50;last=signal[-1]-50
    interior=rows[first:last+1]
    gaps=[];run=0
    for row in interior+[{'rms':1000}]:
        if row['rms']<150:run+=20
        elif run:gaps.append(run);run=0
    foreign=[r for r in rows if r['rms']>=150 and r['foreign_ratio']>.1 and r['foreign_fraction']>=.05]
    return {'passed':len(interior)>=50 and not foreign and max(gaps,default=0)<=100,
        'expected_hz':expected,'duration_ms':len(raw)*1000/rate,'analyzed_ms':len(interior)*20,
        'first_signal_ms':rows[signal[0]]['ms'],'last_signal_ms':rows[signal[-1]]['ms'],
        'foreign_windows':len(foreign),'max_foreign_energy_fraction':max((r['foreign_fraction'] for r in rows if r['rms']>=150),default=0),'max_foreign_ratio':max((r['foreign_ratio'] for r in interior),default=0),
        'gap_count':len(gaps),'gap_total_ms':sum(gaps),'gap_max_ms':max(gaps,default=0),
        'rms_min':min((r['rms'] for r in interior),default=0),
        'limits':'20 ms windows; identity across all audible windows requires foreign tone >10% of expected tone power and >=5% total energy; one-second edge exclusion for gaps only; 100 ms internal-gap ceiling. No attribution of packet loss or speech quality.'}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('pcm',type=Path);p.add_argument('--rate',type=int,required=True)
    p.add_argument('--expected',type=int,required=True);p.add_argument('--frequencies',required=True)
    p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    result=analyze(a.pcm,a.rate,a.expected,[int(v) for v in a.frequencies.split(',')])
    a.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
    sys.exit(0 if result['passed'] else 1)
