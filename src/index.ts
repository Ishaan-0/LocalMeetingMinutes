import { Command } from 'commander';
import { startRecording, stopRecording} from './recorder';
import { createMeetingPage, appendContentToPage } from './notion';
import { transcribe} from './transcriber';
import { generateMOM } from './llm';

const program = new Command();

program
    .command('record') 
    .description('Start recording the meeting')
    .action(() => {
        startRecording();
        console.log('Recording started. Run "npm start stop" to stop');
    });

program 
    .command('stop')
    .description('Stop recording the meeting and process the audio')
    .action(async () => {
        const wavPath = await stopRecording();
        console.log('Processing audio...');
        try {
            const transcript = await transcribe(wavPath);
            console.log('Transcription completed. Generating Minutes of Meeting...');
            const { title, body_output } = await generateMOM(transcript);
            const date = new Date().toLocaleDateString();
            console.log('MOM generated. Creating Notion page...');
            const pageId = await createMeetingPage(title, date);
            await appendContentToPage(pageId, '## Transcript\n' + transcript);
            await appendContentToPage(pageId, '## Minutes of Meeting\n' + body_output);
            console.log('MOM saved to Notion successfully!');
        } catch (error) {
            console.error('Error processing meeting:', error);
        }
    });

program.parse(process.argv);

