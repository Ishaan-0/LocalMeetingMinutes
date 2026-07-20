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
