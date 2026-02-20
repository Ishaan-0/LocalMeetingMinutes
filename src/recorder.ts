import { spawn, ChildProcess } from 'child_process';
import { once } from 'node:events';
import path from 'path';
import fs  from 'fs';


const pidFile = path.join(__dirname, '../temp/recording.pid'); 
const ffmpeg_cmd = 'ffmpeg';
const outputPath = path.join(__dirname, '../temp/new_file.wav'); 
const args = ['-f', 'avfoundation', '-i', ':0', '-ar', '16000', '-ac', '1', outputPath];



function startRecording() {
    if (fs.existsSync(pidFile)) {
        console.warn('Recording is already in progress.');
        return;
    }

    const ffmpegProcess = spawn(ffmpeg_cmd, args);
    fs.writeFileSync(pidFile, ffmpegProcess.pid!.toString());
    console.log('Starting recording...');

    /*ffmpegProcess.stderr.on('data', (data) => {
    console.error(`ffmpeg stderr: ${data}`);
    });*/
}

async function stopRecording(): Promise<string> {
    if (!fs.existsSync(pidFile)) {
        throw new Error('No recording in progress to stop.');
    }
    
    const pid = parseInt(fs.readFileSync(pidFile, 'utf-8'));
    process.kill(pid, 'SIGINT');
    fs.unlinkSync(pidFile); // deleting the pid file

    await new Promise(resolve => setTimeout(resolve, 3500)); // wait for ffmpeg to finish writing the file
    
    console.log('Recording stopped. Output saved to:', outputPath);

    return outputPath;
}

export { startRecording, stopRecording };








