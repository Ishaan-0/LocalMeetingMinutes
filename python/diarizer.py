import numpy as np
import soundfile as sf
import tempfile
import os
from pyannote.audio import Pipeline

class Diarizer:
    def __init__(self, hf_token: str) -> None:
        self._pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            use_auth_token=hf_token,
        )

    def diarize(self, audio: np.ndarray, sample_rate: int = 16000) -> list[dict]:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            tmp_path = f.name
        try:
            sf.write(tmp_path, audio, sample_rate)
            diarization = self._pipeline(tmp_path)
            turns = []
            for turn, _, speaker in diarization.itertracks(yield_label=True):
                turns.append({"speaker": speaker, "start": turn.start, "end": turn.end})
            return turns
        finally:
            os.unlink(tmp_path)
