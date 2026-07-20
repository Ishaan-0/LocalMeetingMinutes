from dataclasses import dataclass


@dataclass
class MergedSegment:
    id: str
    speaker_label: str
    text: str
    start_time: float
    end_time: float


@dataclass
class _PyanoTurn:
    raw_speaker: str
    start: float
    end: float


class Merger:
    def __init__(self) -> None:
        self._whisper_segments: list[tuple[str, float, float]] = []
        self._pyannote_turns: list[_PyanoTurn] = []
        self._speaker_map: dict[str, str] = {}
        self._next_speaker_num = 1

    def add_whisper_segment(self, text: str, start: float, end: float) -> None:
        self._whisper_segments.append((text, start, end))

    def add_pyannote_turn(self, raw_speaker: str, start: float, end: float) -> None:
        self._pyannote_turns.append(_PyanoTurn(raw_speaker, start, end))
        if raw_speaker not in self._speaker_map:
            self._speaker_map[raw_speaker] = f"Speaker {self._next_speaker_num}"
            self._next_speaker_num += 1

    def _speaker_at(self, midpoint: float) -> str:
        for turn in self._pyannote_turns:
            if turn.start <= midpoint < turn.end:
                return self._speaker_map[turn.raw_speaker]
        return "Speaker 1"

    def get_merged(self) -> list[MergedSegment]:
        result = []
        for i, (text, start, end) in enumerate(self._whisper_segments):
            mid = (start + end) / 2
            label = self._speaker_at(mid)
            result.append(MergedSegment(
                id=str(i),
                speaker_label=label,
                text=text,
                start_time=start,
                end_time=end,
            ))
        return result
