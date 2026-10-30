import { existsSync } from 'node:fs';
import { app, run } from './common.mjs';
const args = process.argv.slice(2);
const editor = args.includes('--editor-test');
let paths = args.filter(arg => arg !== '--editor-test');
if (!paths.length) paths = ['VST/IVGI2.vst', 'VST3/IVGI2.vst3', 'VST/TDR Nova.vst', 'VST3/TDR Nova.vst3'].map(path => '/Library/Audio/Plug-Ins/' + path).filter(existsSync);
if (!paths.length) throw new Error('Pass paths to installed Apple Silicon .vst/.vst3 bundles.');
await run('npm', ['run', 'build:app']);
// Each external plug-in test runs in its own process.
for (const path of paths) await run(app + '/Contents/MacOS/Sounder', ['--plugin-test', path, ...(editor ? ['--editor-test'] : [])]);
