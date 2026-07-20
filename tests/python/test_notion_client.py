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
