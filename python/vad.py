import numpy as np
import torch

class VAD:
    def __init__(self, threshold: float = 0.5) -> None:
        self.threshold = threshold
        self._model, _ = torch.hub.load(
            repo_or_dir="snakers4/silero-vad",
            model="silero_vad",
            force_reload=False,
            onnx=False,
        )
        self._model.eval()

    def is_speech(self, chunk: np.ndarray, sample_rate: int = 16000) -> bool:
        window_size = 512 if sample_rate == 16000 else 256
        audio = chunk.copy()
        # Pad to multiple of window_size
        remainder = len(audio) % window_size
        if remainder:
            audio = np.pad(audio, (0, window_size - remainder))
        windows = audio.reshape(-1, window_size)
        max_prob = 0.0
        with torch.no_grad():
            for win in windows:
                tensor = torch.from_numpy(win).float().unsqueeze(0)
                prob = self._model(tensor, sample_rate).item()
                if prob > max_prob:
                    max_prob = prob
        return max_prob >= self.threshold
