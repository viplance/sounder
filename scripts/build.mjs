import { buildCodecs } from './build-codecs.mjs';
import { root, identity, capture, run } from './common.mjs';
buildCodecs();
const identities = capture('security', ['find-identity', '-v', '-p', 'codesigning']);
const signing = identities.includes(identity) ? identity : '-';
console.log(signing === '-' ? 'Developer ID unavailable; using local ad-hoc signature.' : `Signing: ${signing}`);
await run('xcodebuild', ['-project', 'Sounder.xcodeproj', '-scheme', 'Sounder', '-configuration', 'Release', '-derivedDataPath', root + 'build/DerivedData', 'build', 'SYMROOT=' + root + 'build', 'CODE_SIGN_IDENTITY=' + signing, 'CODE_SIGNING_REQUIRED=YES']);
