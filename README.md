# Meeting Minutes Recorder

## System Requirements
- Node.js 18+
- ffmpeg (`brew install ffmpeg`)
- Ollama (`ollama.com`) with `llama3.2:3b` pulled
- whisper.cpp compiled at `/Volumes/T7/tools/whisper.cpp`
- BlackHole 2ch audio driver (`existential.audio/blackhole`)

## Setup
1. Clone the repo
2. Run `npm install`
3. Copy `.env.example` to `.env` and fill in your Notion credentials
4. Follow audio setup instructions below

## Usage
```bash
npm start record   # start recording
npm start stop     # stop and process
```
```

Also create a `.env.example` file so other users know what environment variables they need:
```
NOTION_TOKEN=your_notion_integration_token

NOTION_DATABASE_ID=your_database_id
