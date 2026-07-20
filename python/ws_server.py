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
