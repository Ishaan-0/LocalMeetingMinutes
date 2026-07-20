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
