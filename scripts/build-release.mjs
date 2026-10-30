import { mkdir, rm, cp, symlink } from 'node:fs/promises';
import { root, app, identity, capture, run } from './common.mjs';
if (!capture('security', ['find-identity', '-v', '-p', 'codesigning']).includes(identity)) throw new Error('Developer ID signing certificate is required for release.');
await run('npm', ['run', 'build:app']);
await run('codesign', ['--force', '--sign', identity, '--options', 'runtime', '--timestamp', '--entitlements', root + 'Sounder/Sounder.entitlements', app]);
await run('codesign', ['--verify', '--deep', '--strict', app]);
const staging = root + 'build/dmg'; const dmg = root + 'build/Sounder.dmg';
await rm(staging, { recursive: true, force: true }); await mkdir(staging, { recursive: true });
await cp(app, staging + '/Sounder.app', { recursive: true }); await symlink('/Applications', staging + '/Applications');
await run('hdiutil', ['create', '-volname', 'Sounder', '-srcfolder', staging, '-ov', '-format', 'UDZO', dmg]);
await run('codesign', ['--force', '--sign', identity, dmg]);
if (!process.argv.includes('--skip-notarize')) {
  await run('xcrun', ['notarytool', 'submit', dmg, '--keychain-profile', process.env.NOTARY_PROFILE || 'falcon-notary', '--wait']);
  await run('xcrun', ['stapler', 'staple', dmg]);
}
console.log(dmg);
