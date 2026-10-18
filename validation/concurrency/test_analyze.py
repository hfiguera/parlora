import math
import tempfile
import unittest
from array import array
from pathlib import Path
from analyze import analyze

class ToneChecks(unittest.TestCase):
    rate=24000
    def check_audio(self, make):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'audio.pcm'
            pcm=array('h',(round(make(i/self.rate)) for i in range(5*self.rate)))
            import sys
            if sys.byteorder!='little': pcm.byteswap()
            p.write_bytes(pcm.tobytes())
            return analyze(p,self.rate,500,[500,900,1300,1700])
    def test_clean(self):
        self.assertTrue(self.check_audio(lambda t:6000*math.sin(2*math.pi*500*t))['passed'])
    def test_wrong_route(self):
        self.assertFalse(self.check_audio(lambda t:6000*math.sin(2*math.pi*900*t))['passed'])
    def test_mixed_routes(self):
        result=self.check_audio(lambda t:6000*math.sin(2*math.pi*500*t)+3000*math.sin(2*math.pi*900*t))
        self.assertFalse(result['passed']);self.assertGreater(result['foreign_windows'],0)
    def test_gap(self):
        result=self.check_audio(lambda t:0 if 2<t<2.3 else 6000*math.sin(2*math.pi*500*t))
        self.assertFalse(result['passed']);self.assertGreater(result['gap_max_ms'],100)
    def test_foreign_audio_at_start_is_not_excluded(self):
        result=self.check_audio(lambda t:6000*math.sin(2*math.pi*(900 if t<.5 else 500)*t))
        self.assertFalse(result['passed']);self.assertGreater(result['foreign_windows'],0)
    def test_recorded_broadband_codec_close_tail_is_not_a_foreign_tone(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'tail.pcm'
            tone=array('h',(round(6000*math.sin(2*math.pi*900*i/48000)) for i in range(5*48000)))
            import sys
            if sys.byteorder!='little':tone.byteswap()
            p.write_bytes(tone.tobytes()+(Path(__file__).parent/'fixtures/codec-close-tail.pcm').read_bytes())
            self.assertTrue(analyze(p,48000,900,[500,900,1300,1700])['passed'])
    def test_quiet_coherent_foreign_tone_still_fails(self):
        result=self.check_audio(lambda t:(300*math.sin(2*math.pi*900*t)) if t<.5 else 6000*math.sin(2*math.pi*500*t))
        self.assertFalse(result['passed']);self.assertGreater(result['foreign_windows'],0)
    def test_silence(self):
        self.assertFalse(self.check_audio(lambda t:0)['passed'])

if __name__=='__main__':unittest.main()
