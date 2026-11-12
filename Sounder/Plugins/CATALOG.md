# Downloadable VST3 catalog

`PluginCatalog.json` is the local source of truth and is copied into the app bundle by Xcode. Downloads were checked on 2026-11-09. All nine archives contain native Apple Silicon VST3 binaries. The app downloads directly from the manufacturer or the manufacturer's linked file host; it does not redistribute their binaries.

| Purpose | Plug-in | Official source | Selection evidence / notes |
| --- | --- | --- | --- |
| Dynamic EQ | TDR Nova 2.2.3 | [Tokyo Dawn Labs](https://www.tokyodawn.net/tdr-nova/) | [KVR user reviews](https://www.kvraudio.com/product/tdr-nova-by-tokyo-dawn-labs/reviews); free edition, not Nova GE. |
| Transparent limiter | LoudMax 1.47 | [Thomas Mundt](https://loudmax.blogspot.com/) | [KVR user reviews](https://www.kvraudio.com/product/loudmax-by-thomas-mundt); the official site links to the notarized macOS ZIP on Dropbox. Use light reduction for individual vocals/instruments. |
| Compressor | TDR Kotelnikov 1.6.7 | [Tokyo Dawn Labs](https://www.tokyodawn.net/tdr-kotelnikov/) | The manufacturer includes feedback from mastering/audio engineers; free edition, not Kotelnikov GE. |
| Reverb | TAL-Reverb-4 4.0.4 | [TAL Software](https://tal-software.com/products/tal-reverb-4) | [KVR user reviews](https://www.kvraudio.com/product/tal-reverb-4-by-tal-software/reviews). Chosen for immediate use without registration. [Convology XT](https://wavearts.com/products/plugins/convology/) is free but requires a serial number and separate factory IR content. |
| Vocal tuning | CanaryVoiceTune 1.0.3 | [Enotix](https://vst.e-notix.com/) | Explicitly requested; no independently verified user-review score is claimed. |
| Maximizer | MaxOx 1.0.3 | [Enotix](https://vst.e-notix.com/) | Explicitly requested; no independently verified user-review score is claimed. |
| Tape saturation | Tape Snake 1.0.1 | [Enotix](https://vst.e-notix.com/) | Explicitly requested; no independently verified user-review score is claimed. |
| Amp modeling | TONE3000 0.0.12 | [Official download](https://www.tone3000.com/plugin/download) | Uses the producer's GitHub release linked by that page. [The producer's guide](https://www.tone3000.com/guides/tone3000-plugin) explains that loading online tones requires a free account; local NAM/IR files work offline. |
| Noise gate | Auburn Sounds Renegate Free 1.6.0 | [Auburn Sounds](https://www.auburnsounds.com/products/Renegate.html) | [KVR user reviews](https://www.kvraudio.com/marketplace/renegate-by-auburn-sounds), including Free-edition feedback. Advanced Full-edition functions are not included. |

## Installation behavior

The picker combines installed plug-ins with missing catalog entries. Search and arrow navigation never install anything. Only the row's **Install** button starts a download. After installation every open FX picker is rescanned; the selected plug-in is added once through the existing effect-add path and its editor opens. An installed plug-in has an ordinary row without Install. If a recording began while the download was in progress, insertion waits until recording finishes rather than interrupting the take.

The progress window uses the same compact file/progress row and Cancel/Close interaction as audio import/export. Download/hash/copy progress measures bytes; package expansion/signature checks show an indeterminate phase. Downloading, hashing, expansion and copying run off the main thread. Closing the main editor or quitting during installation cancels the job first; minimizing/restoring the editor includes its progress window.

Only the selected `.vst3` bundle is installed, under `~/Library/Audio/Plug-Ins/VST3`. Other formats, standalone applications, package scripts and optional external factory-preset collections are not installed. Existing system/user plug-ins are detected; the installer does not overwrite a different bundle or ask for administrator access. Native signatures and arm64 support are checked before an atomic publication from a staging directory. Downloaded archives and incomplete staging directories are removed after success, cancellation or failure. User projects retain their normal source/media behavior.

## Updating the catalog

Each entry records a stable ID, display information, producer homepage, direct HTTPS download URL, archive type, SHA-256, byte count, expected VST3 bundle filename and bundle identifier. Some archives contain a macOS package; the app expands it as data without running installer scripts. Component packages whose payload starts at `Contents` are reconstructed only when their declared install location matches the expected VST3 filename.

When updating an entry, download the producer's macOS archive, inspect the actual VST3/arm64 bundle, verify its signature, and update the version, size and SHA-256 together. Mutable producer download URLs intentionally fail verification when their contents change until the local catalog is updated. Do not substitute third-party mirrors or remove checksum verification.

Run `Sounder --plugin-install-test` for picker/cancellation/corrupt-download checks. To exercise actual archives without touching the user's VST3 directory, put verified downloads in a temporary directory as `<id>.zip` / `<id>.pkg` and run `Sounder --plugin-install-test --plugin-archives /path/to/archives`. That optional check installs into a disposable directory and loads every bundle in the real VST3 host.


CanaryVoiceTune is downloaded from the developer HTTPS URL in PluginCatalog.json. No VST3 binaries or installation archives are shipped inside Sounder.app. Updates to the developer archive require a matching catalog checksum and byte count.
