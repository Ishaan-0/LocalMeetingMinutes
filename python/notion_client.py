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
