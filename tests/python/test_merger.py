import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../python'))

from merger import Merger, MergedSegment

def test_single_speaker_no_diarization():
    m = Merger()
    m.add_whisper_segment("Hello world", 0.0, 2.0)
    result = m.get_merged()
    assert len(result) == 1
    assert result[0].text == "Hello world"
    assert result[0].speaker_label == "Speaker 1"  # default when no diarization

def test_diarization_assigns_speaker():
    m = Merger()
    m.add_pyannote_turn("SPEAKER_00", 0.0, 3.0)
    m.add_pyannote_turn("SPEAKER_01", 3.0, 6.0)
    m.add_whisper_segment("I said this", 0.5, 2.5)
    m.add_whisper_segment("You said that", 3.5, 5.5)
    result = m.get_merged()
    assert result[0].speaker_label == "Speaker 1"
    assert result[1].speaker_label == "Speaker 2"

def test_speaker_mapping_is_consistent():
    m = Merger()
    m.add_pyannote_turn("SPEAKER_00", 0.0, 2.0)
    m.add_pyannote_turn("SPEAKER_01", 2.0, 4.0)
    m.add_pyannote_turn("SPEAKER_00", 4.0, 6.0)  # same speaker returns
    m.add_whisper_segment("first", 0.5, 1.5)
    m.add_whisper_segment("second", 2.5, 3.5)
    m.add_whisper_segment("third", 4.5, 5.5)
    result = m.get_merged()
    assert result[0].speaker_label == result[2].speaker_label  # SPEAKER_00 both times
    assert result[0].speaker_label != result[1].speaker_label
