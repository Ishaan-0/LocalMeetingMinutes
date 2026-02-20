// Define the type for the data you are sending
interface OllamaRequest {
    model: string; 
    prompt: string;
    stream: boolean;
    num_predict?: number; // Optional, default is 600 for the MOM use case
}

// Define the type for the response data (if successful)
interface OllamaResponse {
  model: string;
  response: string;
  done: boolean;
}

interface MOMResult {
    title: string; 
    body_output: string;
}

async function generateMOM(transcript: string): Promise<MOMResult> {
    const truncatedTranscript = transcript.length > 4000 
    ? transcript.slice(0, 4000) + '...[truncated]'
    : transcript;

    const url = 'http://localhost:11434/api/generate'; // Ollama API endpoint

    const prompt = `You are a meeting assistant. Given the transcript below, produce a Minutes of Meeting document.

STRICT FORMATTING RULES - follow these exactly:
- Use "## " for main section headings
- Use "### " for sub-headings  
- Use "- " for all bullet points, never use * for bullets
- Never use **bold** or any other markdown formatting
- Never add any preamble like "Minutes of Meeting" or "Date" at the top
- Keep language concise and direct

OUTPUT THESE SECTIONS IN ORDER:
## Title
(one line, max 6 words, describing the meeting topic)
## Summary
## Key Decisions
## Action Items
## Topics Discussed

Transcript:
${truncatedTranscript}`;

    const body: OllamaRequest = {
        model: 'llama3.2:3b',
        prompt: prompt,
        stream: false,
        num_predict: 600
    };

    const response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
    });

    if (!response.ok) {
        throw new Error(`Ollama Request Failed, error:  ${response.status}`);
    }

    const data = await response.json() as OllamaResponse;

    const fullOutput = data.response;

    const titleMatch = fullOutput.match(/## Title\s*\n([^\n]+)/);
    const title = (titleMatch&&titleMatch[1]) 
        ? titleMatch[1].trim() 
        : `Meeting - ${new Date().toLocaleDateString()}`;

    // remove the title section from the body
    const body_output = fullOutput.replace(/## Title\s*\n[^\n]+\n?/, '').trim();

    return { title, body_output };
}

export { generateMOM };

/* 
const transcript = `John: Hi everyone, let's start the meeting.
Jan e: Hi John, I have an update on the project. We completed the first phase last week.
John: That's great news, Jane. What about the next steps?
Jane: We will start the second phase next Monday, which involves testing and feedback.
John: Sounds good. Do we have any blockers?
Jane: Not at the moment, but we might need additional resources for testing.
John: I'll look into that. Thanks for the update, Jane.`;

async function main() {
    try {
        const mom = await generateMOM(transcript);
        console.log('Minutes of Meeting:\n', mom);
    } catch (error) {
        console.error('Error generating MOM:', error);
    }
}

main();
*/