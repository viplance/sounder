import { app, run } from './common.mjs';
await run('npm', ['run', 'build:app']);
await run(app + '/Contents/MacOS/Sounder', [process.argv.includes('--buffers') ? '--buffer-regression-test' : '--self-test']);
