# Bundled audio encoder sources

Sounder's optional export formats are implemented by a separate `AudioEncoder` executable. The application bundles this executable; users do not need Homebrew, FFmpeg, LAME, or Vorbis installed.

Source archives are unmodified upstream releases:

| Archive | Source | SHA-256 |
| --- | --- | --- |
| `lame-3.100.tar.gz` | https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz | `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e` |
| `libogg-1.3.6.tar.gz` | https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz | `83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638` |
| `libvorbis-1.3.7.tar.gz` | https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz | `0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab` |

Run `node scripts/build-codecs.mjs` to verify, extract, build and link the helper on Apple Silicon. It compiles the code in `scripts/audio-encoder.c` against the static libraries and leaves all source, objects and libraries under `.build/codecs`. The build strips obsolete `-force_cpusubtype_ALL` flags from extracted configure scripts for compatibility with modern Apple linkers; the archives remain unchanged. Remove `.build/codecs` to rebuild from scratch. The Xcode target copies and signs the helper in `Contents/Helpers`.

LAME uses the GNU Library General Public License, version 2 or later. Ogg/Vorbis use BSD-style licenses. Full upstream license texts are included in each archive and in the application's `ThirdPartyNotices.txt`. These archives, the helper source and build script provide corresponding source and permit modifying/relinking the standalone helper.
