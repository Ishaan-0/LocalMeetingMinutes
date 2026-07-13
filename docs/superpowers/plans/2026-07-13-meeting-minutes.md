# MeetingMinutes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS desktop app that captures meeting audio in real-time, transcribes it with speaker labels using local LLMs, and exports structured minutes to Notion or Markdown.

**Architecture:** Electron (React/TypeScript) shell spawns a Swift binary (ScreenCaptureKit → Unix socket) and a Python hub (VAD + mlx-whisper + pyannote + WebSocket). Data flows one-way: Swift → Python → Electron. Ollama handles post-meeting summarization; Notion is an optional export target.

**Tech Stack:** Electron 33 + electron-vite 2 + React 18 + TypeScript 5, Swift 5.9 (ScreenCaptureKit), Python 3.11 (mlx-whisper, pyannote.audio, silero-vad, websockets, httpx), Ollama REST API, Notion API v1, keytar (macOS Keychain), Vitest + React Testing Library, pytest

## Global Constraints

- macOS 13.0+ required (ScreenCaptureKit)
- Apple Silicon (M1+) required (MLX)
- Ollama must be installed and running — health-checked on startup
- HuggingFace token required for pyannote models — stored in Keychain
- All processing is local; only Notion export and Ollama (localhost) make network calls
- Python deps ship bundled as a venv inside the .app — users never run pip
- Sessions stored as JSON in `~/Library/Application Support/MeetingMinutes/sessions/`
- Notion token and HF token stored in macOS Keychain via keytar
- No pause/resume in v1; single audio source per session

---

## File Structure

```
MeetingMinutes/
├── package.json
├── electron.vite.config.ts
├── tsconfig.json
├── tsconfig.node.json
├── tsconfig.web.json
├── src/
│   ├── main/
│   │   ├── index.ts                # BrowserWindow lifecycle, spawns processes
│   │   ├── process-manager.ts      # Spawn/monitor Swift + Python, auto-restart
│   │   ├── health-check.ts         # Ollama ping, HF token verify, arch check
│   │   ├── session-store.ts        # CRUD for Session JSON files
│   │   ├── keychain.ts             # keytar wrapper: get/set/delete secrets
│   │   └── ipc-handlers.ts         # All ipcMain.handle() registrations
│   ├── preload/
│   │   └── index.ts                # contextBridge API exposed to renderer
│   └── renderer/
│       ├── index.html
│       └── src/
│           ├── main.tsx
│           ├── App.tsx             # React Router: routes between screens
│           ├── types.ts            # Session, Segment, WsEvent, HealthStatus types
│           ├── hooks/
│           │   ├── useWebSocket.ts # WS to Python hub; dispatches transcript events
│           │   └── useSession.ts   # Session state: transcript[], summary, speakerNames
│           ├── screens/
│           │   ├── SetupScreen.tsx
│           │   ├── HomeScreen.tsx
│           │   ├── RecordingScreen.tsx
│           │   └── SummaryScreen.tsx
│           └── components/
│               ├── SourcePickerModal.tsx
│               ├── SpeakerChip.tsx
│               ├── TranscriptPanel.tsx
│               └── HealthBanner.tsx
├── swift/AudioCapture/
│   ├── Package.swift
│   └── Sources/AudioCapture/
│       ├── main.swift
│       ├── ScreenCaptureManager.swift
│       └── SocketStreamer.swift
├── python/
│   ├── requirements.txt
│   ├── hub.py                      # asyncio entry: wires all components
│   ├── audio_receiver.py           # Unix socket server: accept PCM
│   ├── vad.py                      # silero-vad wrapper
│   ├── transcriber.py              # mlx-whisper wrapper
│   ├── diarizer.py                 # pyannote.audio wrapper (thread pool)
│   ├── merger.py                   # Reconcile Whisper text + pyannote speakers
│   ├── ws_server.py                # asyncio WebSocket server: emit events
│   ├── ollama_client.py            # POST transcript → Ollama → structured JSON
│   ├── notion_client.py            # POST structured output → Notion API
│   └── notion_export_cli.py        # One-shot CLI: reads SESSION_JSON env, exports, prints page ID
├── tests/python/
│   ├── test_vad.py
│   ├── test_merger.py
│   ├── test_ollama_client.py
│   └── test_notion_client.py
└── scripts/
    └── bundle-python.sh            # Build self-contained venv for .app bundle
```

---

## Phase 1: Project Scaffold

### Task 1: Electron + Vite + React + TypeScript scaffold

**Files:**
- Create: `package.json`, `electron.vite.config.ts`, `tsconfig.json`, `tsconfig.node.json`, `tsconfig.web.json`
- Create: `src/main/index.ts`, `src/preload/index.ts`, `src/renderer/index.html`, `src/renderer/src/main.tsx`

**Interfaces:**
- Produces: Running Electron app showing a white window at `localhost` (dev) or bundled (prod)

- [ ] **Step 1: Scaffold with electron-vite**

```bash
cd "/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes"
npm create @quick-start/electron@latest . -- --template react-ts
```

Accept all defaults. This creates the full electron-vite boilerplate.

- [ ] **Step 2: Install dependencies**

```bash
npm install
npm install keytar uuid date-fns @radix-ui/react-dialog @radix-ui/react-scroll-area
npm install -D @types/uuid vitest @testing-library/react @testing-library/user-event jsdom @vitest/coverage-v8
```

- [ ] **Step 3: Add test config to `vite.config.ts` (renderer)**

In `electron.vite.config.ts`, add to the renderer config:
```typescript
renderer: {
  // existing config...
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/renderer/src/test-setup.ts'],
  }
}
```

Create `src/renderer/src/test-setup.ts`:
```typescript
import '@testing-library/jest-dom'
```

- [ ] **Step 4: Verify dev mode works**

```bash
npm run dev
```

Expected: Electron window opens showing the default Vite + React page.

- [ ] **Step 5: Commit**

```bash
git init
git add .
git commit -m "feat: scaffold Electron + Vite + React + TypeScript"
```

---

### Task 2: Shared TypeScript types

**Files:**
- Create: `src/renderer/src/types.ts`
- Create: `src/main/types.ts` (same content, duplicated — no shared barrel across main/renderer in electron-vite)

**Interfaces:**
- Produces: `Session`, `Segment`, `WsEvent`, `HealthStatus`, `AudioSource` types used throughout

- [ ] **Step 1: Write `src/renderer/src/types.ts`**

```typescript
export interface Segment {
  id: string
  speakerLabel: string        // "Speaker 1", "Speaker 2"
  speakerName?: string        // user-assigned
  startTime: number           // seconds from recording start
  endTime: number
  text: string
}

export interface Session {
  id: string
  name: string                // user-editable, default "YYYY-MM-DD HH:mm"
  startedAt: string           // ISO timestamp
  endedAt: string
  audioSource: string         // e.g. "Microsoft Teams"
  durationSeconds: number
  transcript: Segment[]
  summary: {
    takeaways: string[]
    actionPoints: string[]
  }
  notionPageId?: string
}

export interface AudioSource {
  id: string                  // ScreenCaptureKit app bundle ID
  name: string                // Display name
  icon?: string               // Base64 PNG (optional)
}

export type WsEvent =
  | { type: 'segment'; id: string; speakerLabel: string; text: string; startTime: number; endTime: number }
  | { type: 'speaker_update'; speakerLabel: string; startTime: number; endTime: number }
  | { type: 'summary'; takeaways: string[]; actionPoints: string[] }
  | { type: 'sources'; sources: AudioSource[] }
  | { type: 'error'; message: string }

export interface HealthStatus {
  ollamaOk: boolean
  ollamaModel?: string        // first available model name
  hfTokenOk: boolean
  isAppleSilicon: boolean
}
```

- [ ] **Step 2: Copy to `src/main/types.ts`**

Same content as above — electron-vite doesn't allow cross-context imports.

- [ ] **Step 3: Verify TypeScript compiles**

```bash
npm run typecheck
```

Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add src/
git commit -m "feat: add shared TypeScript types"
```

---

## Phase 2: Python ML Hub

### Task 3: Python project setup

**Files:**
- Create: `python/requirements.txt`
- Create: `python/hub.py` (stub)

**Interfaces:**
- Produces: `python -m pytest tests/python/` works; `python python/hub.py` starts without import errors

- [ ] **Step 1: Create `python/requirements.txt`**

```
mlx-whisper==0.4.1
pyannote.audio==3.3.2
torch==2.3.1
websockets==12.0
httpx==0.27.0
numpy==1.26.4
soundfile==0.12.1
silero-vad @ git+https://github.com/snakers4/silero-vad@v5.1
pytest==8.2.2
pytest-asyncio==0.23.7
```

- [ ] **Step 2: Create virtualenv and install**

```bash
cd "/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes"
python3.11 -m venv python/.venv
python/.venv/bin/pip install -r python/requirements.txt
```

Expected: All packages install without error. mlx-whisper download may take a few minutes.

- [ ] **Step 3: Create stub `python/hub.py`**

```python
#!/usr/bin/env python3
"""MeetingMinutes Python hub — entry point."""
import asyncio
import argparse


async def main(socket_path: str, ws_port: int, hf_token: str) -> None:
    print(f"Hub starting: socket={socket_path} ws_port={ws_port}", flush=True)
    # Components wired in later tasks
    await asyncio.sleep(0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True, help="Unix socket path for audio input")
    parser.add_argument("--ws-port", type=int, default=8765, help="WebSocket port for Electron")
    parser.add_argument("--hf-token", required=True, help="HuggingFace token for pyannote")
    args = parser.parse_args()
    asyncio.run(main(args.socket, args.ws_port, args.hf_token))
```

- [ ] **Step 4: Verify stub runs**

```bash
python/.venv/bin/python python/hub.py --socket /tmp/test.sock --hf-token dummy
```

Expected: prints `Hub starting:...` and exits.

- [ ] **Step 5: Commit**

```bash
git add python/
git commit -m "feat: Python project setup with requirements"
```

---

### Task 4: Merger (pure logic, test-first)

Start with `merger.py` because it's pure Python with no ML deps — fastest feedback loop.

**Files:**
- Create: `python/merger.py`
- Create: `tests/python/test_merger.py`

**Interfaces:**
- Consumes: Whisper segments `(text, start, end)`, pyannote turns `(speaker, start, end)`
- Produces: `Merger` class with `add_whisper_segment()`, `add_pyannote_turn()`, `get_merged()` → `list[MergedSegment]`

- [ ] **Step 1: Write failing tests**

```python
# tests/python/test_merger.py
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
python/.venv/bin/pytest tests/python/test_merger.py -v
```

Expected: `ModuleNotFoundError: No module named 'merger'`

- [ ] **Step 3: Implement `python/merger.py`**

```python
from dataclasses import dataclass, field
from typing import Optional


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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python/.venv/bin/pytest tests/python/test_merger.py -v
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add python/merger.py tests/python/test_merger.py
git commit -m "feat: add Merger for reconciling Whisper + pyannote timestamps"
```

---

### Task 5: Ollama client

**Files:**
- Create: `python/ollama_client.py`
- Create: `tests/python/test_ollama_client.py`

**Interfaces:**
- Consumes: Full transcript text (string), Ollama base URL, model name
- Produces: `summarize(transcript: str) -> dict` with keys `takeaways: list[str]`, `action_points: list[str]`

- [ ] **Step 1: Write failing tests**

```python
# tests/python/test_ollama_client.py
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../python'))

import pytest
import httpx
from unittest.mock import patch, MagicMock
from ollama_client import OllamaClient, OllamaError


def _mock_response(json_body: dict) -> MagicMock:
    r = MagicMock(spec=httpx.Response)
    r.status_code = 200
    r.json.return_value = json_body
    r.raise_for_status = MagicMock()
    return r


def test_summarize_parses_json_response():
    client = OllamaClient(base_url="http://localhost:11434", model="llama3.2:3b")
    response_content = '{"takeaways": ["Key point 1"], "action_points": ["Alice to follow up"]}'
    mock_resp = _mock_response({"response": response_content})
    with patch("httpx.post", return_value=mock_resp):
        result = client.summarize("Alice: Hello\nBob: Hi")
    assert result["takeaways"] == ["Key point 1"]
    assert result["action_points"] == ["Alice to follow up"]


def test_summarize_raises_on_http_error():
    client = OllamaClient(base_url="http://localhost:11434", model="llama3.2:3b")
    mock_resp = MagicMock(spec=httpx.Response)
    mock_resp.raise_for_status.side_effect = httpx.HTTPStatusError(
        "404", request=MagicMock(), response=mock_resp
    )
    with patch("httpx.post", return_value=mock_resp):
        with pytest.raises(OllamaError):
            client.summarize("some transcript")


def test_summarize_raises_when_json_malformed():
    client = OllamaClient(base_url="http://localhost:11434", model="llama3.2:3b")
    mock_resp = _mock_response({"response": "This is not JSON at all"})
    with patch("httpx.post", return_value=mock_resp):
        with pytest.raises(OllamaError, match="parse"):
            client.summarize("some transcript")
```

- [ ] **Step 2: Run to verify they fail**

```bash
python/.venv/bin/pytest tests/python/test_ollama_client.py -v
```

Expected: `ModuleNotFoundError: No module named 'ollama_client'`

- [ ] **Step 3: Implement `python/ollama_client.py`**

```python
import json
import httpx

PROMPT_TEMPLATE = """You are a meeting minutes assistant. Given the transcript below, extract:
1. Important takeaways (max 5 bullet points, concise)
2. Action points with owner name if mentioned

Respond ONLY with valid JSON in this exact format:
{{"takeaways": ["...", "..."], "action_points": ["...", "..."]}}

Transcript:
{transcript}"""


class OllamaError(Exception):
    pass


class OllamaClient:
    def __init__(self, base_url: str = "http://localhost:11434", model: str = "llama3.2:3b") -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model

    def summarize(self, transcript: str) -> dict:
        payload = {
            "model": self.model,
            "prompt": PROMPT_TEMPLATE.format(transcript=transcript),
            "stream": False,
        }
        try:
            response = httpx.post(
                f"{self.base_url}/api/generate",
                json=payload,
                timeout=120.0,
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as e:
            raise OllamaError(f"Ollama request failed: {e}") from e
        except httpx.RequestError as e:
            raise OllamaError(f"Ollama connection error: {e}") from e

        raw = response.json().get("response", "")
        try:
            cleaned = raw.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip()
            return json.loads(cleaned)
        except json.JSONDecodeError as e:
            raise OllamaError(f"Failed to parse Ollama response as JSON: {e}\nRaw: {raw}") from e

    def ping(self) -> tuple[bool, str | None]:
        """Returns (ok, first_model_name_or_None)."""
        try:
            r = httpx.get(f"{self.base_url}/api/tags", timeout=5.0)
            r.raise_for_status()
            models = r.json().get("models", [])
            first = models[0]["name"] if models else None
            return True, first
        except Exception:
            return False, None
```

- [ ] **Step 4: Run tests**

```bash
python/.venv/bin/pytest tests/python/test_ollama_client.py -v
```

Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add python/ollama_client.py tests/python/test_ollama_client.py
git commit -m "feat: add OllamaClient for meeting summarization"
```

---

### Task 6: Notion client

**Files:**
- Create: `python/notion_client.py`
- Create: `python/notion_export_cli.py`
- Create: `tests/python/test_notion_client.py`

**Interfaces:**
- Consumes: `Session` dict, Notion API token, database ID
- Produces: `NotionClient.export_session(session: dict) -> str` (returns created page ID)

- [ ] **Step 1: Write failing tests**

```python
# tests/python/test_notion_client.py
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../python'))

import pytest
from unittest.mock import patch, MagicMock
import httpx
from notion_client import NotionClient, NotionError

SAMPLE_SESSION = {
    "id": "abc123",
    "name": "2026-07-13 14:32",
    "transcript": [
        {"speakerLabel": "Speaker 1", "text": "Hello world", "startTime": 0.0, "endTime": 2.0}
    ],
    "summary": {
        "takeaways": ["Key point"],
        "actionPoints": ["Alice to follow up"],
    },
}

def _mock_post(page_id="page_xyz"):
    mock = MagicMock(spec=httpx.Response)
    mock.status_code = 200
    mock.json.return_value = {"id": page_id}
    mock.raise_for_status = MagicMock()
    return mock

def test_export_returns_page_id():
    client = NotionClient(token="secret_abc", database_id="db_123")
    with patch("httpx.post", return_value=_mock_post("page_xyz")) as mock_post:
        page_id = client.export_session(SAMPLE_SESSION)
    assert page_id == "page_xyz"

def test_export_sends_correct_title():
    client = NotionClient(token="secret_abc", database_id="db_123")
    with patch("httpx.post", return_value=_mock_post()) as mock_post:
        client.export_session(SAMPLE_SESSION)
    call_body = mock_post.call_args.kwargs["json"]
    title_content = call_body["properties"]["Name"]["title"][0]["text"]["content"]
    assert title_content == "2026-07-13 14:32"

def test_export_raises_on_http_error():
    client = NotionClient(token="secret_abc", database_id="db_123")
    mock_resp = MagicMock(spec=httpx.Response)
    mock_resp.raise_for_status.side_effect = httpx.HTTPStatusError(
        "401", request=MagicMock(), response=mock_resp
    )
    with patch("httpx.post", return_value=mock_resp):
        with pytest.raises(NotionError):
            client.export_session(SAMPLE_SESSION)
```

- [ ] **Step 2: Run to verify they fail**

```bash
python/.venv/bin/pytest tests/python/test_notion_client.py -v
```

Expected: `ModuleNotFoundError: No module named 'notion_client'`

- [ ] **Step 3: Implement `python/notion_client.py`**

```python
import httpx

NOTION_API = "https://api.notion.com/v1"
NOTION_VERSION = "2022-06-28"


class NotionError(Exception):
    pass


class NotionClient:
    def __init__(self, token: str, database_id: str) -> None:
        self.token = token
        self.database_id = database_id
        self._headers = {
            "Authorization": f"Bearer {token}",
            "Notion-Version": NOTION_VERSION,
            "Content-Type": "application/json",
        }

    def export_session(self, session: dict) -> str:
        transcript_text = self._format_transcript(session["transcript"])
        takeaways_text = "\n".join(f"• {t}" for t in session["summary"]["takeaways"])
        action_points_text = "\n".join(f"• {a}" for a in session["summary"]["actionPoints"])

        body = {
            "parent": {"database_id": self.database_id},
            "properties": {
                "Name": {"title": [{"text": {"content": session["name"]}}]},
                "Content": {"rich_text": [{"text": {"content": transcript_text[:2000]}}]},
                "Important Takeaways": {"rich_text": [{"text": {"content": takeaways_text}}]},
                "Action Points": {"rich_text": [{"text": {"content": action_points_text}}]},
            },
        }
        try:
            response = httpx.post(
                f"{NOTION_API}/pages",
                headers=self._headers,
                json=body,
                timeout=30.0,
            )
            response.raise_for_status()
            return response.json()["id"]
        except httpx.HTTPStatusError as e:
            raise NotionError(f"Notion API error: {e}") from e
        except httpx.RequestError as e:
            raise NotionError(f"Notion connection error: {e}") from e

    def _format_transcript(self, segments: list[dict]) -> str:
        lines = []
        for seg in segments:
            name = seg.get("speakerName") or seg["speakerLabel"]
            lines.append(f"{name}: {seg['text']}")
        return "\n".join(lines)
```

- [ ] **Step 4: Run tests**

```bash
python/.venv/bin/pytest tests/python/test_notion_client.py -v
```

Expected: 3 passed.

- [ ] **Step 5: Write `python/notion_export_cli.py`**

```python
#!/usr/bin/env python3
"""One-shot Notion export. Called by Electron main process with env vars set."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from notion_client import NotionClient, NotionError

token = os.environ.get("NOTION_TOKEN", "")
db_id = os.environ.get("NOTION_DB_ID", "")
session_json = os.environ.get("SESSION_JSON", "")

if not token or not db_id or not session_json:
    print("Missing NOTION_TOKEN, NOTION_DB_ID, or SESSION_JSON", file=sys.stderr)
    sys.exit(1)

try:
    session = json.loads(session_json)
    client = NotionClient(token=token, database_id=db_id)
    page_id = client.export_session(session)
    print(page_id)
except NotionError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
```

- [ ] **Step 6: Commit**

```bash
git add python/notion_client.py python/notion_export_cli.py tests/python/test_notion_client.py
git commit -m "feat: add NotionClient and notion_export_cli for session export"
```

---

### Task 7: VAD, transcriber, diarizer, audio receiver

**Files:**
- Create: `python/vad.py`
- Create: `python/transcriber.py`
- Create: `python/diarizer.py`
- Create: `python/audio_receiver.py`
- Create: `tests/python/test_vad.py`

**Interfaces:**
- `VAD.is_speech(chunk: np.ndarray, sample_rate: int) -> bool`
- `Transcriber.transcribe(audio: np.ndarray, sample_rate: int) -> list[dict]` → `[{text, start, end}]`
- `Diarizer.diarize(audio_path: str) -> list[dict]` → `[{speaker, start, end}]`
- `AudioReceiver(socket_path: str)` — async context manager; `__aiter__` yields `np.ndarray` chunks

- [ ] **Step 1: Write `python/vad.py`**

```python
import numpy as np
import torch

class VAD:
    def __init__(self, threshold: float = 0.5) -> None:
        self.threshold = threshold
        self._model, self._utils = torch.hub.load(
            repo_or_dir="snakers4/silero-vad",
            model="silero_vad",
            force_reload=False,
            onnx=False,
        )
        self._model.eval()

    def is_speech(self, chunk: np.ndarray, sample_rate: int = 16000) -> bool:
        tensor = torch.from_numpy(chunk).float()
        if tensor.dim() == 1:
            tensor = tensor.unsqueeze(0)
        with torch.no_grad():
            prob = self._model(tensor, sample_rate).item()
        return prob >= self.threshold
```

- [ ] **Step 2: Write `python/transcriber.py`**

```python
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
```

- [ ] **Step 3: Write `python/diarizer.py`**

```python
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
```

- [ ] **Step 4: Write `python/audio_receiver.py`**

```python
import asyncio
import numpy as np
import os
from typing import AsyncIterator

CHUNK_BYTES = 3200  # 100ms of 16kHz mono int16


class AudioReceiver:
    def __init__(self, socket_path: str) -> None:
        self.socket_path = socket_path
        self._server: asyncio.Server | None = None
        self._queue: asyncio.Queue[np.ndarray | None] = asyncio.Queue()

    async def __aenter__(self) -> "AudioReceiver":
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        self._server = await asyncio.start_unix_server(
            self._handle_client, path=self.socket_path
        )
        return self

    async def __aexit__(self, *_) -> None:
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        await self._queue.put(None)

    async def _handle_client(self, reader: asyncio.StreamReader, _writer: asyncio.StreamWriter) -> None:
        while True:
            data = await reader.read(CHUNK_BYTES)
            if not data:
                break
            if len(data) < CHUNK_BYTES:
                data = data.ljust(CHUNK_BYTES, b'\x00')
            pcm = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
            await self._queue.put(pcm)

    def __aiter__(self) -> AsyncIterator[np.ndarray]:
        return self

    async def __anext__(self) -> np.ndarray:
        chunk = await self._queue.get()
        if chunk is None:
            raise StopAsyncIteration
        return chunk
```

- [ ] **Step 5: Write smoke test for VAD**

```python
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
```

- [ ] **Step 6: Run VAD tests**

```bash
python/.venv/bin/pytest tests/python/test_vad.py -v -s
```

Expected: 2 passed. First run may take ~30s for model download.

- [ ] **Step 7: Commit**

```bash
git add python/vad.py python/transcriber.py python/diarizer.py python/audio_receiver.py tests/python/test_vad.py
git commit -m "feat: add VAD, transcriber, diarizer, audio receiver"
```

---

### Task 8: WebSocket server + hub orchestrator

**Files:**
- Create: `python/ws_server.py`
- Modify: `python/hub.py` (wire all components together)

**Interfaces:**
- Produces: WebSocket server on `ws://localhost:{port}` emitting `WsEvent` JSON

- [ ] **Step 1: Write `python/ws_server.py`**

```python
import asyncio
import json
import websockets
from websockets.server import WebSocketServerProtocol

class WsServer:
    def __init__(self, port: int = 8765) -> None:
        self.port = port
        self._clients: set[WebSocketServerProtocol] = set()
        self._server = None

    async def start(self) -> None:
        self._server = await websockets.serve(self._register, "localhost", self.port)

    async def stop(self) -> None:
        if self._server:
            self._server.close()
            await self._server.wait_closed()

    async def _register(self, ws: WebSocketServerProtocol) -> None:
        self._clients.add(ws)
        try:
            await ws.wait_closed()
        finally:
            self._clients.discard(ws)

    async def broadcast(self, event: dict) -> None:
        if not self._clients:
            return
        message = json.dumps(event)
        await asyncio.gather(
            *(client.send(message) for client in self._clients),
            return_exceptions=True,
        )
```

- [ ] **Step 2: Write the full `python/hub.py`**

```python
#!/usr/bin/env python3
"""MeetingMinutes Python hub — orchestrates all ML components."""
import asyncio
import argparse
import uuid
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from audio_receiver import AudioReceiver
from vad import VAD
from transcriber import Transcriber
from diarizer import Diarizer
from merger import Merger
from ws_server import WsServer
from ollama_client import OllamaClient

SAMPLE_RATE = 16000
SPEECH_BUFFER_SILENCE_CHUNKS = 5
DIARIZE_MIN_SECONDS = 15.0

async def main(socket_path: str, ws_port: int, hf_token: str, ollama_url: str, ollama_model: str) -> None:
    executor = ThreadPoolExecutor(max_workers=2)
    loop = asyncio.get_event_loop()

    print("Loading ML models...", flush=True)
    vad = VAD()
    transcriber = Transcriber()
    diarizer = Diarizer(hf_token=hf_token)
    merger = Merger()
    ollama = OllamaClient(base_url=ollama_url, model=ollama_model)
    ws = WsServer(port=ws_port)

    await ws.start()
    print(f"WebSocket server listening on ws://localhost:{ws_port}", flush=True)

    full_audio: list[np.ndarray] = []
    speech_buffer: list[np.ndarray] = []
    silence_count = 0

    async def flush_speech_buffer() -> None:
        nonlocal silence_count, speech_buffer
        if not speech_buffer:
            return
        audio_segment = np.concatenate(speech_buffer)
        speech_buffer = []
        silence_count = 0

        segments = await loop.run_in_executor(
            executor, transcriber.transcribe, audio_segment, SAMPLE_RATE
        )
        for seg in segments:
            merger.add_whisper_segment(seg["text"], seg["start"], seg["end"])
            merged = merger.get_merged()
            last = merged[-1] if merged else None
            if last:
                await ws.broadcast({
                    "type": "segment",
                    "id": str(uuid.uuid4()),
                    "speakerLabel": last.speaker_label,
                    "text": last.text,
                    "startTime": last.start_time,
                    "endTime": last.end_time,
                })

    async def run_diarization_update() -> None:
        if not full_audio:
            return
        combined = np.concatenate(full_audio)
        if len(combined) / SAMPLE_RATE < DIARIZE_MIN_SECONDS:
            return
        turns = await loop.run_in_executor(executor, diarizer.diarize, combined, SAMPLE_RATE)
        for turn in turns:
            merger.add_pyannote_turn(turn["speaker"], turn["start"], turn["end"])
        for seg in merger.get_merged():
            await ws.broadcast({
                "type": "speaker_update",
                "speakerLabel": seg.speaker_label,
                "startTime": seg.start_time,
                "endTime": seg.end_time,
            })

    diarize_task: asyncio.Task | None = None
    chunks_since_diarize = 0
    DIARIZE_EVERY_CHUNKS = 150

    async with AudioReceiver(socket_path) as receiver:
        print(f"Audio receiver ready at {socket_path}", flush=True)
        async for chunk in receiver:
            full_audio.append(chunk)
            chunks_since_diarize += 1

            if vad.is_speech(chunk, SAMPLE_RATE):
                speech_buffer.append(chunk)
                silence_count = 0
            else:
                if speech_buffer:
                    silence_count += 1
                    speech_buffer.append(chunk)
                    if silence_count >= SPEECH_BUFFER_SILENCE_CHUNKS:
                        await flush_speech_buffer()

            if chunks_since_diarize >= DIARIZE_EVERY_CHUNKS:
                chunks_since_diarize = 0
                if diarize_task is None or diarize_task.done():
                    diarize_task = asyncio.create_task(run_diarization_update())

    await flush_speech_buffer()
    await run_diarization_update()

    merged = merger.get_merged()
    transcript_text = "\n".join(f"{s.speaker_label}: {s.text}" for s in merged)
    try:
        summary = ollama.summarize(transcript_text)
        await ws.broadcast({
            "type": "summary",
            "takeaways": summary.get("takeaways", []),
            "actionPoints": summary.get("action_points", []),
        })
    except Exception as e:
        await ws.broadcast({"type": "error", "message": f"Summarization failed: {e}"})

    await ws.stop()
    executor.shutdown(wait=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--ws-port", type=int, default=8765)
    parser.add_argument("--hf-token", required=True)
    parser.add_argument("--ollama-url", default="http://localhost:11434")
    parser.add_argument("--ollama-model", default="llama3.2:3b")
    args = parser.parse_args()
    asyncio.run(main(args.socket, args.ws_port, args.hf_token, args.ollama_url, args.ollama_model))
```

- [ ] **Step 3: Verify hub imports cleanly**

```bash
python/.venv/bin/python -c "import hub; print('OK')"
```

Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add python/ws_server.py python/hub.py
git commit -m "feat: add WebSocket server and hub orchestrator"
```

---

## Phase 3: Swift Audio Binary

### Task 9: Swift package + socket streamer

**Files:**
- Create: `swift/AudioCapture/Package.swift`
- Create: `swift/AudioCapture/Sources/AudioCapture/SocketStreamer.swift`
- Create: `swift/AudioCapture/Sources/AudioCapture/main.swift` (stub)

**Interfaces:**
- Produces: `SocketStreamer` that connects to a Unix socket and writes raw PCM Data

- [ ] **Step 1: Create `swift/AudioCapture/Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioCapture",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AudioCapture",
            path: "Sources/AudioCapture"
        ),
    ]
)
```

- [ ] **Step 2: Create stub `swift/AudioCapture/Sources/AudioCapture/main.swift`**

```swift
import Foundation

var standardError = FileHandle.standardError
extension FileHandle: TextOutputStream {
    public func write(_ string: String) {
        let data = Data(string.utf8)
        self.write(data)
    }
}

print("AudioCapture binary starting", to: &standardError)
```

- [ ] **Step 3: Create `swift/AudioCapture/Sources/AudioCapture/SocketStreamer.swift`**

```swift
import Foundation
import Network

final class SocketStreamer {
    private let socketPath: String
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.meetingminutes.socket")

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func connect() throws {
        let endpoint = NWEndpoint.unix(path: socketPath)
        let params = NWParameters()
        params.allowLocalEndpointReuse = true
        connection = NWConnection(to: endpoint, using: params)
        connection?.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                fputs("Socket connection failed: \(error)\n", stderr)
            default:
                break
            }
        }
        connection?.start(queue: queue)
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}
```

- [ ] **Step 4: Build to verify it compiles**

```bash
cd swift/AudioCapture
swift build
```

Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
cd "/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes"
git add swift/
git commit -m "feat: Swift package scaffold with SocketStreamer"
```

---

### Task 10: ScreenCaptureKit audio capture + main entry

**Files:**
- Create: `swift/AudioCapture/Sources/AudioCapture/ScreenCaptureManager.swift`
- Modify: `swift/AudioCapture/Sources/AudioCapture/main.swift`

**Interfaces:**
- Produces: Compiled `AudioCapture` binary accepting `--socket <path> --app-id <bundleID>` args; streams 16kHz mono int16 PCM to the socket; `--list-apps` prints tab-separated bundleID + name lines

- [ ] **Step 1: Create `ScreenCaptureManager.swift`**

```swift
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreAudio

final class ScreenCaptureManager: NSObject {
    private var stream: SCStream?
    private let streamer: SocketStreamer
    private let appBundleID: String
    private let sampleRate: Double = 16000
    private let semaphore = DispatchSemaphore(value: 0)
    var isRunning = false

    init(streamer: SocketStreamer, appBundleID: String) {
        self.streamer = streamer
        self.appBundleID = appBundleID
    }

    static func listApps() async throws -> [(bundleID: String, name: String)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        var seen = Set<String>()
        var result: [(String, String)] = []
        for app in content.applications {
            let bid = app.bundleIdentifier
            if !seen.contains(bid) {
                seen.insert(bid)
                result.append((bid, app.applicationName))
            }
        }
        return result.sorted { $0.1 < $1.1 }
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { $0.bundleIdentifier == appBundleID }) else {
            throw CaptureError.appNotFound(appBundleID)
        }

        let filter = SCContentFilter(desktopIndependentWindow: content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == appBundleID
        }) ?? content.windows[0])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1

        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
        try await stream?.startCapture()
        isRunning = true
        fputs("Capturing audio from: \(app.applicationName)\n", stderr)
    }

    func stop() async {
        try? await stream?.stopCapture()
        isRunning = false
        semaphore.signal()
    }

    func waitUntilStopped() {
        semaphore.wait()
    }
}

extension ScreenCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let ptr = dataPointer, length > 0 else { return }

        let data = Data(bytes: ptr, count: length)
        streamer.send(data)
    }
}

enum CaptureError: Error {
    case appNotFound(String)
}
```

- [ ] **Step 2: Replace `main.swift` with full implementation**

```swift
import Foundation

var standardError = FileHandle.standardError
extension FileHandle: TextOutputStream {
    public func write(_ string: String) {
        let data = Data(string.utf8)
        self.write(data)
    }
}

var socketPath: String?
var appBundleID: String?
var listApps = false

var args = CommandLine.arguments.dropFirst()
var it = args.makeIterator()
while let arg = it.next() {
    switch arg {
    case "--socket": socketPath = it.next()
    case "--app-id": appBundleID = it.next()
    case "--list-apps": listApps = true
    default: break
    }
}

if listApps {
    Task {
        do {
            let apps = try await ScreenCaptureManager.listApps()
            for app in apps {
                print("\(app.bundleID)\t\(app.name)")
            }
        } catch {
            fputs("Error listing apps: \(error)\n", stderr)
        }
        exit(0)
    }
} else {
    guard let socket = socketPath, let bundleID = appBundleID else {
        fputs("Usage: AudioCapture --socket <path> --app-id <bundleID>\n       AudioCapture --list-apps\n", stderr)
        exit(1)
    }

    let streamer = SocketStreamer(socketPath: socket)
    let manager = ScreenCaptureManager(streamer: streamer, appBundleID: bundleID)

    Task {
        do {
            try streamer.connect()
            try await manager.start()
        } catch {
            fputs("Failed to start capture: \(error)\n", stderr)
            exit(1)
        }
    }

    signal(SIGTERM) { _ in Task { await manager.stop() } }
    signal(SIGINT) { _ in Task { await manager.stop() } }

    manager.waitUntilStopped()
}

RunLoop.main.run()
```

- [ ] **Step 3: Build release binary**

```bash
cd swift/AudioCapture
swift build -c release
```

Expected: `Build complete!` Binary at `.build/release/AudioCapture`

- [ ] **Step 4: Smoke test --list-apps**

```bash
.build/release/AudioCapture --list-apps
```

Expected: Prints app list (or macOS prompts for Screen Recording permission).

- [ ] **Step 5: Commit**

```bash
cd "/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes"
git add swift/
git commit -m "feat: ScreenCaptureKit audio capture with CLI interface"
```

---

## Phase 4: Electron Main Process

### Task 11: Session store + keychain + health check

**Files:**
- Create: `src/main/session-store.ts`
- Create: `src/main/keychain.ts`
- Create: `src/main/health-check.ts`

**Interfaces:**
- `sessionStore.list() -> Session[]`, `.get(id) -> Session | null`, `.save(session) -> void`, `.delete(id) -> void`
- `keychain.get(key) -> string | null`, `.set(key, value) -> void`, `.delete(key) -> void`
- `runHealthCheck(hfToken: string | null) -> Promise<HealthStatus>`

- [ ] **Step 1: Write `src/main/keychain.ts`**

```typescript
import keytar from 'keytar'

const SERVICE = 'MeetingMinutes'

export const keychain = {
  async get(key: string): Promise<string | null> {
    return keytar.getPassword(SERVICE, key)
  },
  async set(key: string, value: string): Promise<void> {
    await keytar.setPassword(SERVICE, key, value)
  },
  async delete(key: string): Promise<void> {
    await keytar.deletePassword(SERVICE, key)
  },
}
```

- [ ] **Step 2: Write `src/main/session-store.ts`**

```typescript
import fs from 'fs'
import path from 'path'
import { app } from 'electron'
import type { Session } from './types'

function getSessionsDir(): string {
  const dir = path.join(app.getPath('userData'), 'sessions')
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  return dir
}

export const sessionStore = {
  list(): Session[] {
    const dir = getSessionsDir()
    return fs
      .readdirSync(dir)
      .filter((f) => f.endsWith('.json'))
      .map((f) => {
        const raw = fs.readFileSync(path.join(dir, f), 'utf-8')
        return JSON.parse(raw) as Session
      })
      .sort((a, b) => b.startedAt.localeCompare(a.startedAt))
  },

  get(id: string): Session | null {
    const file = path.join(getSessionsDir(), `${id}.json`)
    if (!fs.existsSync(file)) return null
    return JSON.parse(fs.readFileSync(file, 'utf-8')) as Session
  },

  save(session: Session): void {
    const file = path.join(getSessionsDir(), `${session.id}.json`)
    fs.writeFileSync(file, JSON.stringify(session, null, 2), 'utf-8')
  },

  delete(id: string): void {
    const file = path.join(getSessionsDir(), `${id}.json`)
    if (fs.existsSync(file)) fs.unlinkSync(file)
  },
}
```

- [ ] **Step 3: Write `src/main/health-check.ts`**

```typescript
import { execSync } from 'child_process'
import http from 'http'
import type { HealthStatus } from './types'

function isAppleSilicon(): boolean {
  try {
    const arch = execSync('uname -m', { encoding: 'utf-8' }).trim()
    return arch === 'arm64'
  } catch {
    return false
  }
}

function pingOllama(): Promise<{ ok: boolean; model?: string }> {
  return new Promise((resolve) => {
    const req = http.get('http://localhost:11434/api/tags', { timeout: 4000 }, (res) => {
      let body = ''
      res.on('data', (chunk) => (body += chunk))
      res.on('end', () => {
        try {
          const data = JSON.parse(body)
          const models: { name: string }[] = data.models ?? []
          resolve({ ok: true, model: models[0]?.name })
        } catch {
          resolve({ ok: false })
        }
      })
    })
    req.on('error', () => resolve({ ok: false }))
    req.on('timeout', () => { req.destroy(); resolve({ ok: false }) })
  })
}

export async function runHealthCheck(hfToken: string | null): Promise<HealthStatus> {
  const [{ ok: ollamaOk, model }, isArm] = await Promise.all([
    pingOllama(),
    Promise.resolve(isAppleSilicon()),
  ])
  return {
    isAppleSilicon: isArm,
    ollamaOk,
    ollamaModel: model,
    hfTokenOk: !!hfToken && hfToken.startsWith('hf_'),
  }
}
```

- [ ] **Step 4: Commit**

```bash
git add src/main/session-store.ts src/main/keychain.ts src/main/health-check.ts
git commit -m "feat: session store, keychain wrapper, health check"
```

---

### Task 12: Process manager + IPC handlers + main entry

**Files:**
- Create: `src/main/process-manager.ts`
- Create: `src/main/ipc-handlers.ts`
- Modify: `src/main/index.ts`
- Modify: `src/preload/index.ts`

**Interfaces:**
- Produces: Electron app that spawns Python hub + Swift binary on recording start; exposes IPC API to renderer

- [ ] **Step 1: Write `src/main/process-manager.ts`**

```typescript
import { ChildProcess, spawn } from 'child_process'
import path from 'path'
import { app } from 'electron'
import os from 'os'

const SOCKET_PATH = path.join(os.tmpdir(), 'meetingminutes-audio.sock')
const WS_PORT = 8765

function resourcePath(...parts: string[]): string {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, ...parts)
  }
  return path.join(__dirname, '../../..', ...parts)
}

export class ProcessManager {
  private pythonProcess: ChildProcess | null = null
  private swiftProcess: ChildProcess | null = null
  readonly socketPath = SOCKET_PATH
  readonly wsPort = WS_PORT

  getResourcePath(...parts: string[]): string {
    return resourcePath(...parts)
  }

  startPython(hfToken: string): void {
    const pythonBin = resourcePath('python-bundle', 'bin', 'python3')
    const hubScript = resourcePath('python', 'hub.py')
    this.pythonProcess = spawn(pythonBin, [
      hubScript,
      '--socket', SOCKET_PATH,
      '--ws-port', String(WS_PORT),
      '--hf-token', hfToken,
    ])
    this.pythonProcess.stderr?.on('data', (d) => console.log('[Python]', d.toString().trim()))
    this.pythonProcess.on('exit', (code) => console.log(`[Python] exited with code ${code}`))
  }

  async listAudioSources(): Promise<{ id: string; name: string }[]> {
    return new Promise((resolve, reject) => {
      const bin = resourcePath('swift-bin', 'AudioCapture')
      const proc = spawn(bin, ['--list-apps'])
      let output = ''
      proc.stdout?.on('data', (d) => (output += d.toString()))
      proc.on('close', () => {
        const sources = output
          .trim()
          .split('\n')
          .filter(Boolean)
          .map((line) => {
            const [id, ...nameParts] = line.split('\t')
            return { id, name: nameParts.join('\t') }
          })
        resolve(sources)
      })
      proc.on('error', reject)
    })
  }

  startCapture(appBundleID: string): void {
    const bin = resourcePath('swift-bin', 'AudioCapture')
    this.swiftProcess = spawn(bin, ['--socket', SOCKET_PATH, '--app-id', appBundleID])
    this.swiftProcess.stderr?.on('data', (d) => console.log('[Swift]', d.toString().trim()))
  }

  stopCapture(): void {
    this.swiftProcess?.kill('SIGTERM')
    this.swiftProcess = null
  }

  stopPython(): void {
    this.pythonProcess?.kill('SIGTERM')
    this.pythonProcess = null
  }

  stopAll(): void {
    this.stopCapture()
    this.stopPython()
  }
}
```

- [ ] **Step 2: Write `src/main/ipc-handlers.ts`**

```typescript
import { ipcMain } from 'electron'
import { spawn } from 'child_process'
import { keychain } from './keychain'
import { sessionStore } from './session-store'
import { runHealthCheck } from './health-check'
import { ProcessManager } from './process-manager'
import type { Session } from './types'

export function registerIpcHandlers(pm: ProcessManager): void {
  ipcMain.handle('health:check', async () => {
    const hfToken = await keychain.get('hf-token')
    return runHealthCheck(hfToken)
  })

  ipcMain.handle('keychain:get', (_e, key: string) => keychain.get(key))
  ipcMain.handle('keychain:set', (_e, key: string, value: string) => keychain.set(key, value))
  ipcMain.handle('keychain:delete', (_e, key: string) => keychain.delete(key))

  ipcMain.handle('sessions:list', () => sessionStore.list())
  ipcMain.handle('sessions:get', (_e, id: string) => sessionStore.get(id))
  ipcMain.handle('sessions:save', (_e, session: Session) => sessionStore.save(session))
  ipcMain.handle('sessions:delete', (_e, id: string) => sessionStore.delete(id))

  ipcMain.handle('sources:list', () => pm.listAudioSources())

  ipcMain.handle('recording:start', async (_e, appBundleID: string) => {
    const hfToken = await keychain.get('hf-token')
    if (!hfToken) throw new Error('HuggingFace token not set')
    pm.startPython(hfToken)
    await new Promise((r) => setTimeout(r, 2000))
    pm.startCapture(appBundleID)
  })

  ipcMain.handle('recording:stop', () => {
    pm.stopCapture()
  })

  ipcMain.handle('notion:export', async (_e, session: Session) => {
    const token = await keychain.get('notion-token')
    const dbId = await keychain.get('notion-db-id')
    if (!token || !dbId) throw new Error('Notion not connected. Save a token and database ID first.')

    return new Promise<string>((resolve, reject) => {
      const pythonBin = pm.getResourcePath('python-bundle', 'bin', 'python3')
      const script = pm.getResourcePath('python', 'notion_export_cli.py')
      const proc = spawn(pythonBin, [script], {
        env: {
          ...process.env,
          NOTION_TOKEN: token,
          NOTION_DB_ID: dbId,
          SESSION_JSON: JSON.stringify(session),
        },
      })
      let output = ''
      let errOutput = ''
      proc.stdout?.on('data', (d: Buffer) => (output += d.toString()))
      proc.stderr?.on('data', (d: Buffer) => (errOutput += d.toString()))
      proc.on('close', (code: number) => {
        if (code === 0) resolve(output.trim())
        else reject(new Error(errOutput || `notion_export_cli.py exited with code ${code}`))
      })
    })
  })
}
```

- [ ] **Step 3: Update `src/preload/index.ts`**

```typescript
import { contextBridge, ipcRenderer } from 'electron'

const api = {
  health: {
    check: () => ipcRenderer.invoke('health:check'),
  },
  keychain: {
    get: (key: string) => ipcRenderer.invoke('keychain:get', key),
    set: (key: string, value: string) => ipcRenderer.invoke('keychain:set', key, value),
    delete: (key: string) => ipcRenderer.invoke('keychain:delete', key),
  },
  sessions: {
    list: () => ipcRenderer.invoke('sessions:list'),
    get: (id: string) => ipcRenderer.invoke('sessions:get', id),
    save: (session: unknown) => ipcRenderer.invoke('sessions:save', session),
    delete: (id: string) => ipcRenderer.invoke('sessions:delete', id),
  },
  sources: {
    list: () => ipcRenderer.invoke('sources:list'),
  },
  recording: {
    start: (appBundleID: string) => ipcRenderer.invoke('recording:start', appBundleID),
    stop: () => ipcRenderer.invoke('recording:stop'),
  },
  notion: {
    export: (session: unknown) => ipcRenderer.invoke('notion:export', session),
  },
}

contextBridge.exposeInMainWorld('api', api)

export type ElectronAPI = typeof api
```

- [ ] **Step 4: Update `src/main/index.ts`**

```typescript
import { app, BrowserWindow } from 'electron'
import { join } from 'path'
import { ProcessManager } from './process-manager'
import { registerIpcHandlers } from './ipc-handlers'

const pm = new ProcessManager()

function createWindow(): BrowserWindow {
  const win = new BrowserWindow({
    width: 1024,
    height: 720,
    minWidth: 800,
    minHeight: 600,
    webPreferences: {
      preload: join(__dirname, '../preload/index.js'),
      sandbox: false,
    },
    titleBarStyle: 'hiddenInset',
    backgroundColor: '#0f0f0f',
  })

  if (process.env['ELECTRON_RENDERER_URL']) {
    win.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    win.loadFile(join(__dirname, '../renderer/index.html'))
  }

  return win
}

app.whenReady().then(() => {
  registerIpcHandlers(pm)
  createWindow()
})

app.on('window-all-closed', () => {
  pm.stopAll()
  app.quit()
})
```

- [ ] **Step 5: Add global type declaration**

Create `src/renderer/src/electron.d.ts`:
```typescript
import type { ElectronAPI } from '../../preload'
declare global {
  interface Window {
    api: ElectronAPI
  }
}
```

- [ ] **Step 6: Verify app starts**

```bash
npm run dev
```

Expected: Electron window opens. No console errors.

- [ ] **Step 7: Commit**

```bash
git add src/
git commit -m "feat: process manager, IPC handlers, preload bridge, main entry"
```

---

## Phase 5: React UI Screens

### Task 13: App router + shared hooks

**Files:**
- Create: `src/renderer/src/App.tsx`
- Create: `src/renderer/src/hooks/useWebSocket.ts`
- Create: `src/renderer/src/hooks/useSession.ts`

**Interfaces:**
- `useWebSocket(port)` → `{ lastEvent: WsEvent | null, connected: boolean }`
- `useSession()` → `{ session, updateSpeaker, appendSegment, setSummary, reset, renameSpeaker, renameSession, finalize }`

- [ ] **Step 1: Install react-router-dom**

```bash
npm install react-router-dom
```

- [ ] **Step 2: Write `src/renderer/src/hooks/useWebSocket.ts`**

```typescript
import { useEffect, useRef, useState } from 'react'
import type { WsEvent } from '../types'

export function useWebSocket(port: number) {
  const [lastEvent, setLastEvent] = useState<WsEvent | null>(null)
  const [connected, setConnected] = useState(false)
  const wsRef = useRef<WebSocket | null>(null)

  useEffect(() => {
    let ws: WebSocket
    let retryTimeout: ReturnType<typeof setTimeout>

    function connect() {
      ws = new WebSocket(`ws://localhost:${port}`)
      wsRef.current = ws

      ws.onopen = () => setConnected(true)
      ws.onclose = () => {
        setConnected(false)
        retryTimeout = setTimeout(connect, 2000)
      }
      ws.onerror = () => ws.close()
      ws.onmessage = (e) => {
        try {
          const event = JSON.parse(e.data) as WsEvent
          setLastEvent(event)
        } catch {
          // ignore malformed messages
        }
      }
    }

    connect()
    return () => {
      clearTimeout(retryTimeout)
      ws?.close()
    }
  }, [port])

  return { lastEvent, connected }
}
```

- [ ] **Step 3: Write `src/renderer/src/hooks/useSession.ts`**

```typescript
import { useReducer } from 'react'
import { v4 as uuid } from 'uuid'
import { format } from 'date-fns'
import type { Session, Segment } from '../types'

function emptySession(): Session {
  return {
    id: uuid(),
    name: format(new Date(), 'yyyy-MM-dd HH:mm'),
    startedAt: new Date().toISOString(),
    endedAt: '',
    audioSource: '',
    durationSeconds: 0,
    transcript: [],
    summary: { takeaways: [], actionPoints: [] },
  }
}

type Action =
  | { type: 'RESET'; audioSource: string }
  | { type: 'APPEND_SEGMENT'; segment: Segment }
  | { type: 'UPDATE_SPEAKER'; speakerLabel: string; startTime: number; endTime: number }
  | { type: 'SET_SUMMARY'; takeaways: string[]; actionPoints: string[] }
  | { type: 'RENAME_SPEAKER'; speakerLabel: string; speakerName: string }
  | { type: 'RENAME_SESSION'; name: string }
  | { type: 'FINALIZE'; endedAt: string }

function reducer(state: Session, action: Action): Session {
  switch (action.type) {
    case 'RESET':
      return { ...emptySession(), audioSource: action.audioSource }
    case 'APPEND_SEGMENT':
      return { ...state, transcript: [...state.transcript, action.segment] }
    case 'UPDATE_SPEAKER':
      return {
        ...state,
        transcript: state.transcript.map((seg) =>
          seg.startTime >= action.startTime && seg.endTime <= action.endTime
            ? { ...seg, speakerLabel: action.speakerLabel }
            : seg
        ),
      }
    case 'SET_SUMMARY':
      return { ...state, summary: { takeaways: action.takeaways, actionPoints: action.actionPoints } }
    case 'RENAME_SPEAKER':
      return {
        ...state,
        transcript: state.transcript.map((seg) =>
          seg.speakerLabel === action.speakerLabel ? { ...seg, speakerName: action.speakerName } : seg
        ),
      }
    case 'RENAME_SESSION':
      return { ...state, name: action.name }
    case 'FINALIZE':
      return { ...state, endedAt: action.endedAt }
    default:
      return state
  }
}

export function useSession() {
  const [session, dispatch] = useReducer(reducer, emptySession())
  return {
    session,
    reset: (audioSource: string) => dispatch({ type: 'RESET', audioSource }),
    appendSegment: (segment: Segment) => dispatch({ type: 'APPEND_SEGMENT', segment }),
    updateSpeaker: (speakerLabel: string, startTime: number, endTime: number) =>
      dispatch({ type: 'UPDATE_SPEAKER', speakerLabel, startTime, endTime }),
    setSummary: (takeaways: string[], actionPoints: string[]) =>
      dispatch({ type: 'SET_SUMMARY', takeaways, actionPoints }),
    renameSpeaker: (speakerLabel: string, speakerName: string) =>
      dispatch({ type: 'RENAME_SPEAKER', speakerLabel, speakerName }),
    renameSession: (name: string) => dispatch({ type: 'RENAME_SESSION', name }),
    finalize: (endedAt: string) => dispatch({ type: 'FINALIZE', endedAt }),
  }
}
```

- [ ] **Step 4: Write `src/renderer/src/App.tsx`**

```tsx
import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom'
import SetupScreen from './screens/SetupScreen'
import HomeScreen from './screens/HomeScreen'
import RecordingScreen from './screens/RecordingScreen'
import SummaryScreen from './screens/SummaryScreen'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Navigate to="/setup" replace />} />
        <Route path="/setup" element={<SetupScreen />} />
        <Route path="/home" element={<HomeScreen />} />
        <Route path="/recording" element={<RecordingScreen />} />
        <Route path="/summary/:sessionId" element={<SummaryScreen />} />
      </Routes>
    </BrowserRouter>
  )
}
```

- [ ] **Step 5: Commit**

```bash
git add src/renderer/
git commit -m "feat: app router, useWebSocket hook, useSession reducer"
```

---

### Task 14: Setup screen

**Files:**
- Create: `src/renderer/src/screens/SetupScreen.tsx`

- [ ] **Step 1: Write `SetupScreen.tsx`**

```tsx
import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import type { HealthStatus } from '../types'

export default function SetupScreen() {
  const navigate = useNavigate()
  const [status, setStatus] = useState<HealthStatus | null>(null)
  const [hfInput, setHfInput] = useState('')
  const [checking, setChecking] = useState(false)
  const [hfError, setHfError] = useState('')

  async function check() {
    setChecking(true)
    const s = await window.api.health.check()
    setStatus(s)
    setChecking(false)
    if (s.isAppleSilicon && s.ollamaOk && s.hfTokenOk) {
      navigate('/home')
    }
  }

  useEffect(() => { check() }, [])

  async function saveHfToken() {
    if (!hfInput.startsWith('hf_')) {
      setHfError('Token must start with hf_')
      return
    }
    await window.api.keychain.set('hf-token', hfInput)
    setHfError('')
    check()
  }

  if (!status) return <div style={styles.root}><p style={styles.label}>Checking your setup...</p></div>

  return (
    <div style={styles.root}>
      <h1 style={styles.title}>MeetingMinutes Setup</h1>

      {!status.isAppleSilicon && (
        <div style={styles.error}>
          Apple Silicon (M1 or later) is required. This Mac uses an Intel processor and is not supported.
        </div>
      )}

      {status.isAppleSilicon && (
        <>
          <CheckRow ok={status.ollamaOk} label="Ollama is running">
            {!status.ollamaOk && (
              <div style={styles.instructions}>
                <p>Install Ollama from <strong>ollama.com</strong>, then run:</p>
                <code style={styles.code}>ollama pull llama3.2:3b</code>
                <p>Then click Check Again below.</p>
              </div>
            )}
            {status.ollamaOk && status.ollamaModel && (
              <p style={styles.sub}>Model: {status.ollamaModel}</p>
            )}
          </CheckRow>

          <CheckRow ok={status.hfTokenOk} label="HuggingFace token set">
            {!status.hfTokenOk && (
              <div style={styles.instructions}>
                <p>1. Accept model terms at <strong>hf.co/pyannote/speaker-diarization-3.1</strong></p>
                <p>2. Create a token at <strong>hf.co/settings/tokens</strong></p>
                <input
                  style={styles.input}
                  placeholder="hf_..."
                  value={hfInput}
                  onChange={(e) => setHfInput(e.target.value)}
                />
                {hfError && <p style={styles.errorText}>{hfError}</p>}
                <button style={styles.btn} onClick={saveHfToken}>Save Token</button>
              </div>
            )}
          </CheckRow>
        </>
      )}

      <button style={styles.btn} onClick={check} disabled={checking}>
        {checking ? 'Checking...' : 'Check Again'}
      </button>
    </div>
  )
}

function CheckRow({ ok, label, children }: { ok: boolean; label: string; children?: React.ReactNode }) {
  return (
    <div style={{ marginBottom: 20 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ fontSize: 18 }}>{ok ? '✅' : '❌'}</span>
        <span style={{ color: ok ? '#4ade80' : '#f87171', fontWeight: 600 }}>{label}</span>
      </div>
      {!ok && children}
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  root: { padding: 40, maxWidth: 560, margin: '0 auto', fontFamily: 'system-ui', color: '#e5e5e5', background: '#0f0f0f', minHeight: '100vh' },
  title: { fontSize: 28, fontWeight: 700, marginBottom: 32 },
  label: { color: '#9ca3af' },
  error: { background: '#450a0a', border: '1px solid #7f1d1d', borderRadius: 8, padding: 16, marginBottom: 24, color: '#fca5a5' },
  instructions: { marginTop: 8, marginLeft: 26, color: '#9ca3af', fontSize: 14 },
  code: { display: 'block', background: '#1f1f1f', padding: '8px 12px', borderRadius: 6, fontFamily: 'monospace', margin: '8px 0', color: '#86efac' },
  input: { display: 'block', width: '100%', padding: '8px 12px', background: '#1f1f1f', border: '1px solid #374151', borderRadius: 6, color: '#e5e5e5', fontFamily: 'monospace', marginTop: 8 },
  btn: { marginTop: 16, padding: '10px 20px', background: '#3b82f6', color: '#fff', border: 'none', borderRadius: 8, fontWeight: 600, cursor: 'pointer' },
  sub: { marginLeft: 26, marginTop: 4, fontSize: 13, color: '#6b7280' },
  errorText: { color: '#f87171', fontSize: 13 },
}
```

- [ ] **Step 2: Commit**

```bash
git add src/renderer/src/screens/SetupScreen.tsx
git commit -m "feat: setup screen with health checks and onboarding"
```

---

### Task 15: Home screen + source picker modal

**Files:**
- Create: `src/renderer/src/screens/HomeScreen.tsx`
- Create: `src/renderer/src/components/SourcePickerModal.tsx`

- [ ] **Step 1: Write `SourcePickerModal.tsx`**

```tsx
import { useEffect, useState } from 'react'
import type { AudioSource } from '../types'

interface Props {
  onSelect: (source: AudioSource) => void
  onCancel: () => void
}

export default function SourcePickerModal({ onSelect, onCancel }: Props) {
  const [sources, setSources] = useState<AudioSource[]>([])
  const [loading, setLoading] = useState(true)
  const [selected, setSelected] = useState<string | null>(null)

  useEffect(() => {
    window.api.sources.list().then((raw) => {
      setSources(raw.map((s) => ({ id: s.id, name: s.name })))
      setLoading(false)
    })
  }, [])

  function confirm() {
    const source = sources.find((s) => s.id === selected)
    if (source) onSelect(source)
  }

  return (
    <div style={styles.overlay}>
      <div style={styles.modal}>
        <h2 style={styles.title}>Choose Audio Source</h2>
        {loading ? (
          <p style={styles.sub}>Loading running applications...</p>
        ) : sources.length === 0 ? (
          <p style={styles.sub}>No applications with audio found. Start a meeting app first.</p>
        ) : (
          <ul style={styles.list}>
            {sources.map((s) => (
              <li
                key={s.id}
                style={{ ...styles.item, background: selected === s.id ? '#1e3a5f' : '#1f1f1f' }}
                onClick={() => setSelected(s.id)}
              >
                {s.name}
              </li>
            ))}
          </ul>
        )}
        <div style={styles.actions}>
          <button style={styles.cancelBtn} onClick={onCancel}>Cancel</button>
          <button style={styles.startBtn} onClick={confirm} disabled={!selected}>
            Start Recording
          </button>
        </div>
      </div>
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  overlay: { position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.7)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100 },
  modal: { background: '#1a1a1a', border: '1px solid #2d2d2d', borderRadius: 12, padding: 28, width: 420, maxHeight: '70vh', display: 'flex', flexDirection: 'column' },
  title: { margin: '0 0 16px', fontSize: 20, fontWeight: 700, color: '#e5e5e5' },
  sub: { color: '#9ca3af', fontSize: 14 },
  list: { listStyle: 'none', margin: 0, padding: 0, overflowY: 'auto', flex: 1 },
  item: { padding: '10px 14px', borderRadius: 8, marginBottom: 6, cursor: 'pointer', color: '#e5e5e5', fontSize: 14, border: '1px solid #2d2d2d' },
  actions: { display: 'flex', gap: 10, justifyContent: 'flex-end', marginTop: 20 },
  cancelBtn: { padding: '8px 16px', background: 'transparent', border: '1px solid #374151', borderRadius: 8, color: '#9ca3af', cursor: 'pointer' },
  startBtn: { padding: '8px 20px', background: '#3b82f6', border: 'none', borderRadius: 8, color: '#fff', fontWeight: 600, cursor: 'pointer' },
}
```

- [ ] **Step 2: Write `HomeScreen.tsx`**

```tsx
import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { format } from 'date-fns'
import SourcePickerModal from '../components/SourcePickerModal'
import type { Session, AudioSource } from '../types'

export default function HomeScreen() {
  const navigate = useNavigate()
  const [sessions, setSessions] = useState<Session[]>([])
  const [showPicker, setShowPicker] = useState(false)

  useEffect(() => {
    window.api.sessions.list().then(setSessions)
  }, [])

  async function handleSourceSelected(source: AudioSource) {
    setShowPicker(false)
    await window.api.recording.start(source.id)
    navigate('/recording', { state: { audioSource: source.name } })
  }

  return (
    <div style={styles.root}>
      <div style={styles.header}>
        <h1 style={styles.title}>Meeting Minutes</h1>
        <button style={styles.newBtn} onClick={() => setShowPicker(true)}>
          + New Recording
        </button>
      </div>

      {sessions.length === 0 ? (
        <div style={styles.empty}>
          <p>No recordings yet.</p>
          <p style={{ color: '#6b7280', fontSize: 14 }}>Click "New Recording" to get started.</p>
        </div>
      ) : (
        <ul style={styles.list}>
          {sessions.map((s) => (
            <li
              key={s.id}
              style={styles.item}
              onClick={() => navigate(`/summary/${s.id}`)}
            >
              <div style={styles.sessionName}>{s.name}</div>
              <div style={styles.sessionMeta}>
                {s.audioSource} · {format(new Date(s.startedAt), 'MMM d, yyyy')} · {Math.round(s.durationSeconds / 60)}m
              </div>
            </li>
          ))}
        </ul>
      )}

      {showPicker && (
        <SourcePickerModal
          onSelect={handleSourceSelected}
          onCancel={() => setShowPicker(false)}
        />
      )}
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  root: { padding: '32px 40px', fontFamily: 'system-ui', color: '#e5e5e5', background: '#0f0f0f', minHeight: '100vh' },
  header: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 32 },
  title: { fontSize: 26, fontWeight: 700, margin: 0 },
  newBtn: { padding: '10px 20px', background: '#3b82f6', color: '#fff', border: 'none', borderRadius: 8, fontWeight: 600, cursor: 'pointer', fontSize: 15 },
  empty: { textAlign: 'center', marginTop: 100, color: '#9ca3af' },
  list: { listStyle: 'none', margin: 0, padding: 0 },
  item: { padding: '16px 20px', background: '#1a1a1a', border: '1px solid #2d2d2d', borderRadius: 10, marginBottom: 10, cursor: 'pointer' },
  sessionName: { fontWeight: 600, fontSize: 16, marginBottom: 4 },
  sessionMeta: { fontSize: 13, color: '#6b7280' },
}
```

- [ ] **Step 3: Commit**

```bash
git add src/renderer/src/screens/HomeScreen.tsx src/renderer/src/components/SourcePickerModal.tsx
git commit -m "feat: home screen with session list and source picker modal"
```

---

### Task 16: Recording screen

**Files:**
- Create: `src/renderer/src/screens/RecordingScreen.tsx`
- Create: `src/renderer/src/components/SpeakerChip.tsx`
- Create: `src/renderer/src/components/TranscriptPanel.tsx`
- Create: `src/renderer/src/components/HealthBanner.tsx`

- [ ] **Step 1: Write `SpeakerChip.tsx`**

```tsx
import { useState } from 'react'

const COLORS = ['#3b82f6', '#8b5cf6', '#ec4899', '#f59e0b', '#10b981']

function colorFor(label: string): string {
  const n = parseInt(label.replace(/\D/g, '') || '1', 10) - 1
  return COLORS[n % COLORS.length]
}

interface Props {
  label: string
  displayName: string
  onRename: (name: string) => void
}

export default function SpeakerChip({ label, displayName, onRename }: Props) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(displayName)
  const color = colorFor(label)

  function commit() {
    setEditing(false)
    if (draft.trim()) onRename(draft.trim())
  }

  if (editing) {
    return (
      <input
        autoFocus
        style={{ ...chipStyle, background: color, color: '#fff', border: 'none', outline: 'none', width: 100 }}
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={commit}
        onKeyDown={(e) => { if (e.key === 'Enter') commit() }}
      />
    )
  }

  return (
    <span
      style={{ ...chipStyle, background: color + '33', color, border: `1px solid ${color}`, cursor: 'pointer' }}
      onClick={() => { setDraft(displayName); setEditing(true) }}
      title="Click to rename"
    >
      {displayName}
    </span>
  )
}

const chipStyle: React.CSSProperties = {
  display: 'inline-block', padding: '2px 10px', borderRadius: 12, fontSize: 12, fontWeight: 600, marginRight: 6, userSelect: 'none',
}
```

- [ ] **Step 2: Write `TranscriptPanel.tsx`**

```tsx
import { useEffect, useRef } from 'react'
import SpeakerChip from './SpeakerChip'
import type { Segment } from '../types'

interface Props {
  segments: Segment[]
  onRenameSpeaker: (label: string, name: string) => void
}

export default function TranscriptPanel({ segments, onRenameSpeaker }: Props) {
  const bottomRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [segments.length])

  return (
    <div style={styles.panel}>
      {segments.map((seg) => (
        <div key={seg.id} style={styles.segment}>
          <SpeakerChip
            label={seg.speakerLabel}
            displayName={seg.speakerName || seg.speakerLabel}
            onRename={(name) => onRenameSpeaker(seg.speakerLabel, name)}
          />
          <span style={styles.text}>{seg.text}</span>
          <span style={styles.time}>{formatTime(seg.startTime)}</span>
        </div>
      ))}
      <div ref={bottomRef} />
    </div>
  )
}

function formatTime(seconds: number): string {
  const m = Math.floor(seconds / 60)
  const s = Math.floor(seconds % 60)
  return `${m}:${s.toString().padStart(2, '0')}`
}

const styles: Record<string, React.CSSProperties> = {
  panel: { flex: 1, overflowY: 'auto', padding: '16px 20px' },
  segment: { display: 'flex', alignItems: 'flex-start', gap: 8, marginBottom: 12, flexWrap: 'wrap' },
  text: { flex: 1, color: '#e5e5e5', lineHeight: 1.6, fontSize: 15 },
  time: { color: '#4b5563', fontSize: 12, marginTop: 3, whiteSpace: 'nowrap' },
}
```

- [ ] **Step 3: Write `HealthBanner.tsx`**

```tsx
interface Props { visible: boolean }

export default function HealthBanner({ visible }: Props) {
  if (!visible) return null
  return (
    <div style={styles.banner}>
      Ollama is not responding. Recording paused — restart Ollama to resume.
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  banner: { background: '#7f1d1d', color: '#fca5a5', padding: '10px 20px', textAlign: 'center', fontSize: 14, fontWeight: 500 },
}
```

- [ ] **Step 4: Write `RecordingScreen.tsx`**

```tsx
import { useEffect, useState } from 'react'
import { useNavigate, useLocation } from 'react-router-dom'
import TranscriptPanel from '../components/TranscriptPanel'
import HealthBanner from '../components/HealthBanner'
import { useWebSocket } from '../hooks/useWebSocket'
import { useSession } from '../hooks/useSession'

const WS_PORT = 8765

export default function RecordingScreen() {
  const navigate = useNavigate()
  const location = useLocation()
  const audioSource: string = (location.state as { audioSource: string })?.audioSource ?? 'Unknown'

  const { lastEvent, connected } = useWebSocket(WS_PORT)
  const { session, appendSegment, updateSpeaker, setSummary, renameSpeaker, finalize, reset } = useSession()

  const [elapsed, setElapsed] = useState(0)
  const [stopping, setStopping] = useState(false)

  useEffect(() => {
    reset(audioSource)
  }, [])

  useEffect(() => {
    const id = setInterval(() => setElapsed((e) => e + 1), 1000)
    return () => clearInterval(id)
  }, [])

  useEffect(() => {
    if (!lastEvent) return
    if (lastEvent.type === 'segment') {
      appendSegment({
        id: lastEvent.id,
        speakerLabel: lastEvent.speakerLabel,
        text: lastEvent.text,
        startTime: lastEvent.startTime,
        endTime: lastEvent.endTime,
      })
    } else if (lastEvent.type === 'speaker_update') {
      updateSpeaker(lastEvent.speakerLabel, lastEvent.startTime, lastEvent.endTime)
    } else if (lastEvent.type === 'summary') {
      setSummary(lastEvent.takeaways, lastEvent.actionPoints)
      const endedAt = new Date().toISOString()
      finalize(endedAt)
      const finalSession = { ...session, endedAt, durationSeconds: elapsed }
      window.api.sessions.save(finalSession)
      navigate(`/summary/${finalSession.id}`)
    }
  }, [lastEvent])

  async function handleStop() {
    setStopping(true)
    await window.api.recording.stop()
  }

  function formatElapsed(s: number): string {
    const m = Math.floor(s / 60)
    const sec = s % 60
    return `${m}:${sec.toString().padStart(2, '0')}`
  }

  return (
    <div style={styles.root}>
      <HealthBanner visible={!connected && session.transcript.length > 0} />
      <div style={styles.topBar}>
        <div>
          <span style={styles.recDot} />
          <span style={styles.timer}>{formatElapsed(elapsed)}</span>
          <span style={styles.source}>{audioSource}</span>
        </div>
        <button style={styles.stopBtn} onClick={handleStop} disabled={stopping}>
          {stopping ? 'Processing...' : 'Stop'}
        </button>
      </div>
      <TranscriptPanel segments={session.transcript} onRenameSpeaker={renameSpeaker} />
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  root: { display: 'flex', flexDirection: 'column', height: '100vh', background: '#0f0f0f', fontFamily: 'system-ui', color: '#e5e5e5' },
  topBar: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '12px 20px', borderBottom: '1px solid #1f1f1f' },
  recDot: { display: 'inline-block', width: 10, height: 10, background: '#ef4444', borderRadius: '50%', marginRight: 8 },
  timer: { fontSize: 18, fontWeight: 700, fontVariantNumeric: 'tabular-nums', marginRight: 12 },
  source: { fontSize: 13, color: '#6b7280' },
  stopBtn: { padding: '8px 20px', background: '#ef4444', color: '#fff', border: 'none', borderRadius: 8, fontWeight: 600, cursor: 'pointer', fontSize: 14 },
}
```

- [ ] **Step 5: Commit**

```bash
git add src/renderer/src/screens/RecordingScreen.tsx src/renderer/src/components/
git commit -m "feat: recording screen with live transcript and speaker chips"
```

---

### Task 17: Summary screen

**Files:**
- Create: `src/renderer/src/screens/SummaryScreen.tsx`

- [ ] **Step 1: Write `SummaryScreen.tsx`**

```tsx
import { useEffect, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import TranscriptPanel from '../components/TranscriptPanel'
import type { Session } from '../types'

export default function SummaryScreen() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const navigate = useNavigate()
  const [session, setSession] = useState<Session | null>(null)
  const [exporting, setExporting] = useState(false)
  const [exportMsg, setExportMsg] = useState('')

  useEffect(() => {
    if (sessionId) {
      window.api.sessions.get(sessionId).then(setSession)
    }
  }, [sessionId])

  if (!session) return <div style={styles.root}><p>Loading...</p></div>

  async function saveToNotion() {
    if (!session) return
    setExporting(true)
    try {
      const pageId = await window.api.notion.export(session)
      const updated = { ...session, notionPageId: pageId }
      setSession(updated)
      await window.api.sessions.save(updated)
      setExportMsg('Saved to Notion.')
    } catch (e: unknown) {
      setExportMsg(`Export failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setExporting(false)
    }
  }

  function exportMarkdown() {
    if (!session) return
    const lines = [
      `# ${session.name}`,
      '',
      '## Transcript',
      ...session.transcript.map((s) => `**${s.speakerName || s.speakerLabel}:** ${s.text}`),
      '',
      '## Important Takeaways',
      ...session.summary.takeaways.map((t) => `- ${t}`),
      '',
      '## Action Points',
      ...session.summary.actionPoints.map((a) => `- ${a}`),
    ]
    const blob = new Blob([lines.join('\n')], { type: 'text/markdown' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `${session.name.replace(/[/:]/g, '-')}.md`
    a.click()
    URL.revokeObjectURL(url)
  }

  function updateName(name: string) {
    const updated = { ...session, name }
    setSession(updated)
    window.api.sessions.save(updated)
  }

  return (
    <div style={styles.root}>
      <div style={styles.topBar}>
        <button style={styles.backBtn} onClick={() => navigate('/home')}>← Home</button>
        <input
          style={styles.nameInput}
          value={session.name}
          onChange={(e) => updateName(e.target.value)}
        />
        <div style={styles.actions}>
          <button style={styles.actionBtn} onClick={exportMarkdown}>Export Markdown</button>
          <button style={styles.actionBtn} onClick={saveToNotion} disabled={exporting}>
            {exporting ? 'Saving...' : 'Save to Notion'}
          </button>
        </div>
      </div>
      {exportMsg && <div style={styles.msg}>{exportMsg}</div>}
      <div style={styles.body}>
        <div style={styles.left}>
          <h3 style={styles.sectionTitle}>Transcript</h3>
          <TranscriptPanel segments={session.transcript} onRenameSpeaker={() => {}} />
        </div>
        <div style={styles.right}>
          <div style={styles.section}>
            <h3 style={styles.sectionTitle}>Important Takeaways</h3>
            <ul style={styles.bulletList}>
              {session.summary.takeaways.map((t, i) => <li key={i}>{t}</li>)}
            </ul>
          </div>
          <div style={styles.section}>
            <h3 style={styles.sectionTitle}>Action Points</h3>
            <ul style={styles.bulletList}>
              {session.summary.actionPoints.map((a, i) => <li key={i}>{a}</li>)}
            </ul>
          </div>
        </div>
      </div>
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  root: { display: 'flex', flexDirection: 'column', height: '100vh', background: '#0f0f0f', fontFamily: 'system-ui', color: '#e5e5e5' },
  topBar: { display: 'flex', alignItems: 'center', gap: 12, padding: '12px 20px', borderBottom: '1px solid #1f1f1f' },
  backBtn: { background: 'transparent', border: 'none', color: '#6b7280', cursor: 'pointer', fontSize: 14 },
  nameInput: { flex: 1, background: '#1f1f1f', border: '1px solid #2d2d2d', borderRadius: 6, padding: '6px 12px', color: '#e5e5e5', fontSize: 16, fontWeight: 600 },
  actions: { display: 'flex', gap: 8 },
  actionBtn: { padding: '7px 14px', background: '#1f2937', border: '1px solid #374151', borderRadius: 8, color: '#e5e5e5', cursor: 'pointer', fontSize: 13 },
  msg: { padding: '8px 20px', background: '#1f2937', fontSize: 13, color: '#9ca3af' },
  body: { display: 'flex', flex: 1, overflow: 'hidden' },
  left: { flex: 1, borderRight: '1px solid #1f1f1f', display: 'flex', flexDirection: 'column', overflow: 'hidden' },
  right: { width: 340, padding: 20, overflowY: 'auto' },
  section: { marginBottom: 28 },
  sectionTitle: { fontSize: 14, fontWeight: 700, color: '#9ca3af', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 12 },
  bulletList: { paddingLeft: 16, color: '#e5e5e5', lineHeight: 1.8, fontSize: 14 },
}
```

- [ ] **Step 2: Commit**

```bash
git add src/renderer/src/screens/SummaryScreen.tsx
git commit -m "feat: summary screen with two-panel layout and export actions"
```

---

## Phase 6: Build + Distribution

### Task 18: Bundle Python venv + package as .dmg

**Files:**
- Create: `scripts/bundle-python.sh`
- Modify: `package.json` (add build config for electron-builder)
- Create: `build/entitlements.mac.plist`

- [ ] **Step 1: Write `scripts/bundle-python.sh`**

```bash
#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_DIR="$PROJECT_ROOT/resources/python-bundle"

echo "Building Python bundle..."
rm -rf "$BUNDLE_DIR"

python3.11 -m venv "$BUNDLE_DIR"
"$BUNDLE_DIR/bin/pip" install --upgrade pip
"$BUNDLE_DIR/bin/pip" install -r "$PROJECT_ROOT/python/requirements.txt"

find "$BUNDLE_DIR" -name "*.pyc" -delete
find "$BUNDLE_DIR" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

echo "Python bundle created at $BUNDLE_DIR"
echo "Size: $(du -sh $BUNDLE_DIR | cut -f1)"
```

```bash
chmod +x scripts/bundle-python.sh
```

- [ ] **Step 2: Build Swift binary for release**

```bash
cd swift/AudioCapture && swift build -c release
mkdir -p "/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes/resources/swift-bin"
cp .build/release/AudioCapture "/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes/resources/swift-bin/"
cd "/Users/ishaan/Desktop/Throwaway Claude Projects/MeetingMinutes"
```

- [ ] **Step 3: Run Python bundle script**

```bash
bash scripts/bundle-python.sh
```

Expected: `resources/python-bundle/` created.

- [ ] **Step 4: Add electron-builder config to `package.json`**

Add to `package.json`:
```json
"build": {
  "appId": "com.meetingminutes.app",
  "productName": "MeetingMinutes",
  "mac": {
    "target": "dmg",
    "category": "public.app-category.productivity",
    "entitlements": "build/entitlements.mac.plist",
    "entitlementsInherit": "build/entitlements.mac.plist",
    "hardenedRuntime": true,
    "gatekeeperAssess": false
  },
  "extraResources": [
    { "from": "resources/python-bundle", "to": "python-bundle", "filter": ["**/*"] },
    { "from": "resources/swift-bin", "to": "swift-bin", "filter": ["**/*"] },
    { "from": "python", "to": "python", "filter": ["*.py"] }
  ],
  "asarUnpack": ["resources/python-bundle/**", "resources/swift-bin/**"]
}
```

- [ ] **Step 5: Create `build/entitlements.mac.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.screen-capture</key><true/>
</dict>
</plist>
```

- [ ] **Step 6: Build the app**

```bash
npm run build
```

Expected: `dist/` directory created with the packaged app.

- [ ] **Step 7: Add .gitignore entries**

```bash
echo "resources/python-bundle/" >> .gitignore
echo "resources/swift-bin/" >> .gitignore
echo "dist/" >> .gitignore
```

- [ ] **Step 8: Commit**

```bash
git add scripts/ build/ package.json .gitignore
git commit -m "feat: build scripts, entitlements, electron-builder config"
```

---

## Verification Checklist

- [ ] 1. Launch without Ollama running → Setup screen shows Ollama step failing with instructions
- [ ] 2. Launch with Ollama running but no HF token → Setup screen shows HF token step failing
- [ ] 3. Enter HF token → "Check Again" passes and navigates to Home
- [ ] 4. Open Teams + Chrome with Google Meet → both appear in source picker
- [ ] 5. Start recording → transcript begins appearing within ~2s of speech
- [ ] 6. Two people speak → segments labeled "Speaker 1", "Speaker 2"
- [ ] 7. Click "Speaker 1" chip → rename to "Alice" → all Speaker 1 segments update
- [ ] 8. Click Stop → summary screen appears with Takeaways + Action Points
- [ ] 9. Edit session name → persists on reload
- [ ] 10. Export Markdown → `.md` file downloads with correct structure
- [ ] 11. Quit Ollama mid-session → HealthBanner appears
- [ ] 12. Launch on Intel Mac → "Apple Silicon required" message shown immediately
