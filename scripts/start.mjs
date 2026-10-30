import { app, capture, run } from './common.mjs';
// Exact process name, never a broad substring match.
try { capture('pkill', ['-x', 'Sounder']); } catch (error) { if (error.status !== 1) throw error; }
for (let i = 0; i < 30; i++) {
  let running = false;
  try { running = Boolean(capture('pgrep', ['-x', 'Sounder'])); } catch (error) { if (error.status !== 1) throw error; }
  if (!running) break;
  if (i === 29) throw new Error('Previous Sounder instance did not terminate.');
  await new Promise(resolve => setTimeout(resolve, 100));
}
await run('npm', ['run', 'build:app']);
await run('open', [app]);
await new Promise(resolve => setTimeout(resolve, 1500));
const pids = capture('pgrep', ['-x', 'Sounder']).split('\n');
if (pids.length !== 1) throw new Error(`Expected one Sounder process, got ${pids.length}`);
console.log(`Sounder running, PID ${pids[0]}`);
