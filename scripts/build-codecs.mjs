import { spawnSync } from 'node:child_process';
import { mkdirSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const base = root + '.build/codecs';
const prefix = base + '/install';
const packages = [
  ['libogg-1.3.6', '83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638'],
  ['libvorbis-1.3.7', '0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab'],
  ['lame-3.100', 'ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e']
];
const digest = data => createHash('sha256').update(data).digest('hex');
export function buildCodecs() {
  mkdirSync(base, {recursive:true});
  const helper = root + 'scripts/audio-encoder.c';
  const stamp = digest(readFileSync(helper)) + JSON.stringify(packages);
  for (const [name, hash] of packages) {
    if (digest(readFileSync(root + 'Vendor/AudioCodecs/' + name + '.tar.gz')) !== hash) throw new Error('Codec checksum mismatch: ' + name);
  }
  if (existsSync(base + '/AudioEncoder') && existsSync(base + '/stamp') && readFileSync(base + '/stamp', 'utf8') === stamp) return;
  const env = {...process.env, CC:'clang', CFLAGS:'-O2 -arch arm64 -mmacosx-version-min=14.0', LDFLAGS:'-arch arm64 -mmacosx-version-min=14.0', MACOSX_DEPLOYMENT_TARGET:'14.0'};
  function run(cmd,args,cwd=base) {
    const result = spawnSync(cmd,args,{cwd,env,encoding:'utf8',maxBuffer:16*1024*1024});
    if (result.status !== 0) throw new Error(`${cmd} failed: ${result.stdout}\n${result.stderr}`);
  }
  for (const [name] of packages) {
    if (!existsSync(base + '/' + name)) run('tar',['-xzf',root+'Vendor/AudioCodecs/'+name+'.tar.gz']);
    // Older releases add a flag removed from current Apple linkers.
    const configurePath = base + '/' + name + '/configure';
    writeFileSync(configurePath, readFileSync(configurePath, 'utf8').replaceAll('-force_cpusubtype_ALL', ''));
    const library = name.startsWith('libogg') ? 'libogg.a' : name.startsWith('libvorbis') ? 'libvorbisenc.a' : 'libmp3lame.a';
    if (existsSync(prefix + '/lib/' + library)) continue;
    console.log('Building audio codec: ' + name);
    const args = ['--prefix='+prefix,'--disable-shared','--enable-static'];
    if (name.startsWith('libvorbis')) args.push('--with-ogg='+prefix,'--disable-docs','--disable-examples');
    if (name.startsWith('lame')) args.push('--disable-frontend','--disable-decoder','--disable-nasm');
    run('./configure',args,base+'/'+name);
    run('make',['-j8'],base+'/'+name); run('make',['install'],base+'/'+name);
  }
  run('clang',['-O2','-arch','arm64','-mmacosx-version-min=14.0',helper,'-I'+prefix+'/include','-L'+prefix+'/lib','-lmp3lame','-lvorbisenc','-lvorbisfile','-lvorbis','-logg','-lm','-framework','CoreFoundation','-o',base+'/AudioEncoder']);
  writeFileSync(base + '/stamp',stamp);
}
if (process.argv[1] === fileURLToPath(import.meta.url)) buildCodecs();
