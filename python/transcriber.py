import numpy as np
import mlx_whisper

class Transcriber:
    def __init__(self, model: str = "mlx-community/whisper-large-v3-turbo") -> None:
        self.model = model

    def transcribe(self, audio: np.ndarray, sample_rate: int = 16000) -> list[dict]:
        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.model,
            word_timestamps=True,
            language="en",
        )
        segments = []
        for seg in result.get("segments", []):
            segments.append({
                "text": seg["text"].strip(),
                "start": seg["start"],
                "end": seg["end"],
            })
        return segments
