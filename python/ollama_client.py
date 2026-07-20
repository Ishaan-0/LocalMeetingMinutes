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
