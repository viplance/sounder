import { buildCodecs } from './build-codecs.mjs';
import { root, identity, capture, run } from './common.mjs';
buildCodecs();
const identities = capture('security', ['find-identity', '-v', '-p', 'codesigning']);
const signing = identities.includes(identity) ? identity : '-';
if (signing === '-' && process.env.SOUNDER_ALLOW_ADHOC !== '1') {
  throw new Error('Developer ID is unavailable. Build with access to the signing keychain to preserve macOS microphone permission. For an intentional unsigned development build, set SOUNDER_ALLOW_ADHOC=1; permissions can reset after every rebuild.');
}
console.log(signing === '-' ? 'Explicit ad-hoc development build: macOS privacy permissions may reset after rebuilding.' : `Signing: ${signing}`);
await run('xcodebuild', ['-project', 'Sounder.xcodeproj', '-scheme', 'Sounder', '-configuration', 'Release', '-derivedDataPath', root + 'build/DerivedData', 'build', 'SYMROOT=' + root + 'build', 'CODE_SIGN_IDENTITY=' + signing, 'CODE_SIGNING_REQUIRED=YES']);
