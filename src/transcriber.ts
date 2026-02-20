import { spawn, ChildProcess } from 'child_process';
import path from 'path';

const whisper_cmd = '/Volumes/T7/tools/whisper.cpp/build/bin/whisper-cli';
const wav_file_path = path.join(__dirname, '../temp/output.wav');


async function transcribe(wav_file_path: string): Promise<string> {
    return new Promise((resolve, reject) =>{
        const args = ['-m', 
                '/Volumes/T7/tools/whisper.cpp/models/ggml-small.bin', 
                '-f', wav_file_path, 
                '--no-timestamps'
        ];

        const whisperProcess = spawn(whisper_cmd, args);

        let transcription = '';
        whisperProcess.stdout.on('data', (data) => {
            //console.log('whisper stdout:', data.toString());
            transcription += data.toString();
        });

        whisperProcess.on('close', (code) => {
            if(code == 0) {
                //console.log(transcription.trim());
                resolve(transcription.trim());
            } else {
                reject(new Error(`Whisper exited with code ${code}`));
            }
        });
    });
    
}

export { transcribe };

/*
async function main() {
    const audio = await transcribe(wav_file_path);
    console.log('Transcription:', audio);

}

main();
*/