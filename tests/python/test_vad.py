# tests/python/test_vad.py
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../python'))
import numpy as np

def test_vad_silence_returns_false():
    from vad import VAD
    vad = VAD(threshold=0.5)
    silence = np.zeros(1600, dtype=np.float32)
    assert vad.is_speech(silence, sample_rate=16000) is False

def test_vad_returns_bool():
    from vad import VAD
    vad = VAD()
    chunk = np.random.randn(1600).astype(np.float32) * 0.01
    result = vad.is_speech(chunk)
    assert isinstance(result, bool)
