export interface Segment {
  id: string
  speakerLabel: string        // "Speaker 1", "Speaker 2"
  speakerName?: string        // user-assigned
  startTime: number           // seconds from recording start
  endTime: number
  text: string
}

export interface Session {
  id: string
  name: string                // user-editable, default "YYYY-MM-DD HH:mm"
  startedAt: string           // ISO timestamp
  endedAt: string
  audioSource: string         // e.g. "Microsoft Teams"
  durationSeconds: number
  transcript: Segment[]
  summary: {
    takeaways: string[]
    actionPoints: string[]
  }
  notionPageId?: string
}

export interface AudioSource {
  id: string                  // ScreenCaptureKit app bundle ID
  name: string                // Display name
  icon?: string               // Base64 PNG (optional)
}

export type WsEvent =
  | { type: 'segment'; id: string; speakerLabel: string; text: string; startTime: number; endTime: number }
  | { type: 'speaker_update'; speakerLabel: string; startTime: number; endTime: number }
  | { type: 'summary'; takeaways: string[]; actionPoints: string[] }
  | { type: 'sources'; sources: AudioSource[] }
  | { type: 'error'; message: string }

export interface HealthStatus {
  ollamaOk: boolean
  ollamaModel?: string        // first available model name
  hfTokenOk: boolean
  isAppleSilicon: boolean
}
