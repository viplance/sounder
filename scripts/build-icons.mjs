import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const catalog = root + 'Sounder/Assets.xcassets/';
const output = catalog + 'AppIcon.appiconset/';
mkdirSync(output, { recursive: true });
const info = { author: 'xcode', version: 1 };
const images = [];
for (const size of [16, 32, 128, 256, 512]) {
  for (const scale of [1, 2]) {
    const pixels = size * scale;
    const basename = `icon_${size}x${size}${scale === 2 ? '@2x' : ''}`;
    const heic = [64, 128, 256, 512, 1024].includes(pixels);
    const filename = basename + (heic ? '.heic' : '.png');
    const resized = output + basename + '.png';
    // Resize from the lossless master before encoding; never cascade lossy conversions.
    execFileSync('sips', ['-z', String(pixels), String(pixels), root + 'Design/AppIcon/Sounder-master.png', '--out', resized], { stdio: 'ignore' });
    if (heic) {
      execFileSync('sips', ['-s', 'format', 'heic', '-s', 'formatOptions', '85', resized, '--out', output + filename], { stdio: 'ignore' });
      rmSync(resized);
    }
    images.push({ idiom: 'mac', size: `${size}x${size}`, scale: `${scale}x`, filename });
  }
}
execFileSync('sips', ['-z', '1024', '1024', root + 'Design/AppIcon/Sounder-master.png', '--out', root + 'Design/AppIcon/Sounder-AppStore-1024.png'], { stdio: 'ignore' });
writeFileSync(catalog + 'Contents.json', JSON.stringify({ info }, null, 2) + '\n');
writeFileSync(output + 'Contents.json', JSON.stringify({ images, info }, null, 2) + '\n');
console.log('Generated all 10 macOS AppIcon slots, including the 1024 px App Store icon.');
