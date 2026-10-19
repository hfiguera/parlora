"""Analyze a continuous synthetic chirp, not speech or physical audibility.

Uses only the Python standard library. Gaps exclude leading/trailing silence.
Reference alignment/correlation is diagnostic; exact byte equality belongs at PCM
queues before lossy Opus. Receiver sample-rate conversion is explicitly handled.
"""
import argparse
import array
import json
import math
import pathlib
import sys
import wave


def read(path):
    with wave.open(str(path), 'rb') as wav:
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2:
            raise ValueError('Expected mono signed 16-bit WAV')
        rate = wav.getframerate()
        samples = array.array('h', wav.readframes(wav.getnframes()))
    if sys.byteorder != 'little':
        samples.byteswap()
    return rate, samples


def rms(values):
    return math.sqrt(sum(x * x for x in values) / max(1, len(values)))


def frequency(values, rate):
    crossings = [i - values[i] / (values[i+1] - values[i])
                 for i in range(len(values)-1) if values[i] <= 0 < values[i+1]]
    if len(crossings) < 2:
        return 0
    return (len(crossings)-1) * rate / (crossings[-1]-crossings[0])


def analyze(directory):
    rate, received = read(directory / 'received.wav')
    reference_rate, reference = read(directory / 'reference.wav')
    if rate % reference_rate:
        raise ValueError('Receiver rate must be an integer multiple of reference rate')
    # Decimation for alignment only, not a general-purpose audio resampler.
    received = received[::rate // reference_rate]
    width = reference_rate // 100
    levels = [rms(received[i:i + width]) for i in range(0, len(received), width)]
    active = [i for i, value in enumerate(levels) if value >= 100]
    if not active:
        raise ValueError('No decoded signal')
    first, last = active[0], active[-1]
    silent = [i for i in range(first, last + 1) if levels[i] < 100]
    unit = reference_rate // 1000
    millisecond_levels = [rms(received[i:i + unit]) for i in range(0, len(received), unit)]
    # This fixture has a continuous, constant-amplitude chirp. Locate its edges
    # at -20 dB relative to the reference RMS so faint Opus ringing cannot extend
    # the signal into the codec tail. Keep the 100 RMS gap threshold and the
    # 10 ms edge guard; full-level audio on either side still exposes 1 ms gaps.
    edge_threshold = max(100, rms(reference) * .1)
    active_ms = [i for i, value in enumerate(millisecond_levels) if value >= edge_threshold]
    if not active_ms:
        raise ValueError('No decoded signal at reference level')
    interior = range(active_ms[0] + 10, active_ms[-1] - 9)
    silent_ms = [i for i in interior if millisecond_levels[i] < 100]
    longest = current = 0
    silent_set = set(silent_ms)
    for i in interior:
        current = current + 1 if i in silent_set else 0
        longest = max(longest, current)
    # Fit the first second to find codec/receiver delay; this is not future-aware playback.
    probe = reference[:reference_rate:4]
    best = (-1.0, 0)
    for lag in range(max(0, (first - 3) * width), (first + 4) * width):
        segment = received[lag:lag + reference_rate:4]
        if len(segment) != len(probe):
            continue
        score = sum(a * b for a, b in zip(probe, segment))
        score /= math.sqrt(sum(a * a for a in probe) * sum(b * b for b in segment)) or 1
        if score > best[0]:
            best = (score, lag)
    warm = json.loads((directory / 'browser.json').read_text())
    def incoming(records):
        return next((s for s in records if s['type'] == 'inbound-rtp' and s.get('kind') == 'audio'), {})
    before, after = incoming(warm.get('warmStats', [])), incoming(warm.get('stats', []))
    concealed = after.get('concealedSamples', 0) - before.get('concealedSamples', 0)
    # Use the same reference-level millisecond edges as the gap guard. Coarse
    # windows at the quieter gap threshold can include a decaying codec tail.
    signal_first_ms, signal_last_ms = active_ms[0], active_ms[-1]
    duration_ms = signal_last_ms - signal_first_ms + 1
    expected_ms = len(reference) * 1000 / reference_rate
    startup_ms = warm['trackFirstSignalAtMs']-warm['runAtMs'] if 'trackFirstSignalAtMs' in warm else None
    errors = []
    # NetEq legitimately time-stretches audio. Verify the full chirp frequency
    # progression rather than treating a rigid first-second phase match as truth.
    for millisecond in range(signal_first_ms + 100, signal_last_ms - 99, 100):
        segment = received[millisecond * unit:(millisecond + 100) * unit]
        t = ((millisecond - signal_first_ms) * .001 + .05) * expected_ms / duration_ms
        slope = min(70, 3500000 / expected_ms)
        errors.append(abs(frequency(segment, reference_rate) - (220 + slope * t)))
    accelerated_ms = (after.get('removedSamplesForAcceleration',0)-before.get('removedSamplesForAcceleration',0)) * 1000 / rate
    decelerated_ms = (after.get('insertedSamplesForDeceleration',0)-before.get('insertedSamplesForDeceleration',0)) * 1000 / rate
    checks = {'no_internal_silence': not silent_ms,
              'duration_accounting_40ms': expected_ms-accelerated_ms-40 <= duration_ms <= expected_ms+decelerated_ms+40,
              'frequency_progression': bool(errors) and max(errors) <= 15 and sum(errors)/len(errors) <= 5,
              'cleanup': warm.get('cleanup', False),
              'decoded_start_under_300ms': startup_ms is not None and 0 <= startup_ms <= 300,
              'track_capture': 'trackCaptureError' in warm and warm['trackCaptureError'] is None,
              'no_pipeline_failure': not any(e['type'] == 'failure' for e in warm['events']),
              'receiver_statistics': 'concealedSamples' in before and 'concealedSamples' in after,
              'no_steady_concealment': concealed == 0}
    if warm.get('mode') == 'interrupt':
        interruption = next((e for e in warm['events'] if e['type'] == 'interrupted'), {})
        runs = []
        for millisecond in silent_ms:
            if runs and millisecond == runs[-1][-1] + 1:
                runs[-1].append(millisecond)
            else:
                runs.append([millisecond])
        main = max(runs, key=len, default=[])
        # Opus transitions have the same 10 ms edge allowance as the outer
        # signal. Any second gap beyond that guard remains a failure.
        single = bool(main) and all(main[0]-10 <= i <= main[-1]+10 for i in silent_ms)
        checks.pop('no_internal_silence')
        checks.pop('frequency_progression')
        checks.pop('duration_accounting_40ms')
        checks.update({'interruption_observed': 200 <= len(silent_ms) <= 600,
                       'clear_under_200ms': interruption.get('clear_us', 999999) <= 200000,
                       'old_epoch_rejected': interruption.get('old_epoch_rejected', False),
                       'resumed': any(e['type']=='resumed' for e in warm['events']),
                       'post_resume_signal': bool(silent_ms) and signal_last_ms > max(silent_ms)+100,
                       'single_interruption': single})
    report = {'boundary': 'Chromium decoded MediaStreamTrack via TrackProcessor, before WebAudio and speakers', 'checks': checks,
              'passed': all(checks.values()), 'signal_duration_ms': duration_ms,
              'expected_duration_ms': expected_ms, 'decoded_start_ms': startup_ms, 'internal_silence_ms': len(silent_ms), 'coarse_silence_ms': len(silent)*10,
              'longest_silence_ms': longest, 'alignment_samples': best[1],
              'first_second_correlation_diagnostic': best[0],
              'mean_frequency_error_hz': sum(errors)/max(1,len(errors)),
              'max_frequency_error_hz': max(errors,default=0),
              'receiver_accelerated_samples': after.get('removedSamplesForAcceleration',0)-before.get('removedSamplesForAcceleration',0),
              'receiver_decelerated_samples': after.get('insertedSamplesForDeceleration',0)-before.get('insertedSamplesForDeceleration',0), 'steady_concealed_samples': concealed,
              'jitter_seconds': after.get('jitter'), 'server': warm.get('finished')}
    (directory / 'analysis.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=pathlib.Path)
    args = parser.parse_args()
    result = analyze(args.directory)
    print(json.dumps(result, indent=2))
    sys.exit(0 if result['passed'] else 1)
