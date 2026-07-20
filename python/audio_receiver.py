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
