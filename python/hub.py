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
