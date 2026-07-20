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
    loop = asyncio.get_running_loop()

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
    executor.shutdown(wait=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--ws-port", type=int, default=8765)
    parser.add_argument("--hf-token", required=True)
    parser.add_argument("--ollama-url", default="http://localhost:11434")
    parser.add_argument("--ollama-model", default="llama3.2:3b")
    args = parser.parse_args()
    asyncio.run(main(args.socket, args.ws_port, args.hf_token, args.ollama_url, args.ollama_model))
