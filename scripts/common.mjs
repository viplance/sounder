import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
export const root = fileURLToPath(new URL('../', import.meta.url));
export const app = root + 'build/Release/Sounder.app';
export const identity = 'Developer ID Application: Dzmitry Sharko (W37L5728Y6)';
export function capture(command, args) { return execFileSync(command, args, {cwd: root, encoding: 'utf8'}).trim(); }
export function run(command, args) { return new Promise((resolve, reject) => { const child = spawn(command, args, { cwd: root, stdio: 'inherit' }); child.on('error', reject); child.on('exit', code => code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`))); }); }
