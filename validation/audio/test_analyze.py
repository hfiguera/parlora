import importlib.util
import json
import math
import pathlib
import struct
import tempfile
import unittest
import wave

spec = importlib.util.spec_from_file_location('analyze', pathlib.Path(__file__).with_name('analyze.py'))
analyzer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyzer)


class AnalysisTest(unittest.TestCase):
    def fixture(self, transform, mode="normal"):
        reference = [round(8000 * math.sin(2 * math.pi * (220 * n / 24000 + 35 * (n / 24000)**2)))
                     for n in range(48000)]
        received = [0] * 12000 + transform(reference.copy()) + [0] * 12000
        with tempfile.TemporaryDirectory() as tmp:
            directory = pathlib.Path(tmp)
            for name, samples in [('reference', reference), ('received', received)]:
                with wave.open(str(directory / f'{name}.wav'), 'wb') as wav:
                    wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000)
                    wav.writeframes(struct.pack('<' + 'h' * len(samples), *samples))
            stats = [{'type':'inbound-rtp','kind':'audio','concealedSamples':0}]
            (directory / 'browser.json').write_text(json.dumps({'events':([{'type':'interrupted','clear_us':1000,'old_epoch_rejected':True},{'type':'resumed'}] if mode=='interrupt' else []), 'mode':mode, 'cleanup':True,
                'stats':stats, 'warmStats':stats, 'trackCaptureError':None, 'trackFirstSignalAtMs':500, 'runAtMs':380}))
            return analyzer.analyze(directory)

    def test_aligned_signal_with_idle_silence_passes(self):
        self.assertTrue(self.fixture(lambda x:x)['passed'])

    def test_codec_tail_guard_is_independent_of_coarse_block_alignment(self):
        # The final ringing sample extends activity into a coarse block. A quiet
        # millisecond within its last 10 ms belongs to the declared edge guard.
        result = self.fixture(lambda x:[0]*168 + x + [0]*72 + [1000]*24)
        self.assertTrue(result['checks']['no_internal_silence'])
        self.assertTrue(result['checks']['duration_accounting_40ms'])

    def test_quiet_interval_in_decaying_codec_tail_is_not_an_internal_gap(self):
        tail = [round(1200 * math.exp(-n / (24 * 7)) * math.sin(2 * math.pi * 900 * n / 24000))
                for n in range(24 * 35)]
        tail[24 * 4:24 * 5] = [0] * 24
        result = self.fixture(lambda x:x + tail)
        self.assertTrue(result['checks']['no_internal_silence'])
        self.assertTrue(result['checks']['duration_accounting_40ms'])

    def test_one_ms_gap_between_full_level_audio_still_fails(self):
        result = self.fixture(lambda x:x[:24000] + [0]*24 + x[24024:])
        self.assertFalse(result['checks']['no_internal_silence'])

    def test_one_ms_gap_near_end_of_full_level_audio_still_fails(self):
        result = self.fixture(lambda x:x[:-720] + [0]*24 + x[-696:])
        self.assertFalse(result['checks']['no_internal_silence'])

    def test_internal_gap_fails(self):
        result = self.fixture(lambda x:x[:24000] + [0]*960 + x[24960:])
        self.assertFalse(result['checks']['no_internal_silence'])

    def test_subframe_gap_is_not_hidden_by_ten_ms_windows(self):
        result = self.fixture(lambda x:x[:24048]+[0]*120+x[24168:])
        self.assertFalse(result['checks']['no_internal_silence'])

    def test_interruption_allows_only_its_codec_edge(self):
        result = self.fixture(lambda x:x[:24000]+[0]*7200+x[24000:24072]+[0]*24+x[24096:], 'interrupt')
        self.assertTrue(result['passed'])

    def test_second_gap_outside_interruption_edge_fails(self):
        result = self.fixture(lambda x:x[:24000]+[0]*7200+x[24000:36000]+[0]*120+x[36120:], 'interrupt')
        self.assertFalse(result['checks']['single_interruption'])

    def test_duplicated_audio_fails_duration(self):
        result = self.fixture(lambda x:x[:24000] + x[21600:24000] + x[24000:])
        self.assertFalse(result['checks']['duration_accounting_40ms'])

    def test_wrong_signal_fails_progression(self):
        result = self.fixture(lambda x:[round(8000*math.sin(2*math.pi*1000*i/24000)) for i in range(len(x))])
        self.assertFalse(result['checks']['frequency_progression'])

    def test_clipped_tail_fails_duration(self):
        result = self.fixture(lambda x:x[:-2400])
        self.assertFalse(result['checks']['duration_accounting_40ms'])


if __name__ == '__main__':
    unittest.main()
