# Plug-in state ownership

`Editor.pluginHosts` owns the current processors. `PluginEffect.state` is an
immutable serialized snapshot used by project files and history, not a second
live processor. Background preparation may reuse registered processors but may
not replace a conflicting registered host.

## Capture

`capturePluginStates` reads all registered track and MASTER hosts before changing
any project state. A failed read leaves the project snapshots untouched and
prevents Save. Closed and bypassed editors are included. The optional `recordUndo`
records previously unobserved edits at explicit persistence boundaries.

Normal edits call `checkpoint` before mutation. It captures complete plug-in
state first; callers abort when capture fails. Editor polling alone uses
`checkpoint(capturingPlugins: false)`: its nonblocking snapshot already contains
the edited state, and the history entry must retain the preceding state.

## Restore

Open and history transitions retire background preparation, idle/paused audio,
MIDI recipients, editor windows and the host registry before assigning the new
project. Undo/Redo capture the departing live state for the opposite stack.
Editor callbacks additionally check both host and window identity.

## Host serialization

State format 2 stores full VST chunks or VST3 component/controller state. Full
state is authoritative. VST3 also stores pending parameter edits that have not
yet reached DSP; only those edits override the restored component state. The
parameter list is a fallback for processors without full state, and supports
reading older snapshots. Failed full-state capture is reported, not silently
replaced by a parameter-only save.

## Verification

- `--plugin-state-history-test /path/plugin.vst3`: repeated Save/Open using the
  same effect IDs, unprocessed parameter edits, unrelated Undo and Redo.
- `--plugin-persistence-test /path/ConvologyXT.vst3`: opaque impulse state on
  tracks and MASTER, including closed editors and repeated saves.
- `--plugin-test /path/plugin.vst3`: live processor and preparation coverage.

Run the same tests with legacy `.vst` bundles where applicable.
