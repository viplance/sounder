# Playback buffer ownership

`LivePlayback` coordinates transport commands. DSP, source traversal and output
queue refills execute on its serial worker. `ShuttlePlayback` uses the same
output queue and clock components, with its own source resampler.

| Component | Responsibility | Ownership |
| --- | --- | --- |
| PlaybackOutputQueue | Exact block sizes, outstanding callbacks, generations, BUFFER occupancy | Schedule on rendering worker; short accounting lock; consumption publishes immediately |
| PlaybackClock | Output-to-source mapping, monotonic bounded output time, retained loop history | Transport/motion lock; no DSP inside |
| PlaybackTransportState | UI intent and published pause/idle/shuttle state | Short snapshot lock; never wait on worker inside update |
| PlaybackRenderPhase | Inactive, timeline, fading out, idle effects | Playback worker |
| StreamingGraph | Child-before-parent DSP, routing compensation, meters | Playback worker coordinating AudioRenderPlan |
| ProcessedMixCache | Absolute ready regions and processed PCM | Shared I/O lock; bounded 4096-frame write staging |
| PlaybackMeterBuffer | Audible-frame peak snapshots | Bounded 512-entry ring under short lock |
| RecordingPacketTimeline | Input-rate gaps, overlap and pre-roll | Recording writer worker, before conversion |

## Transition rules

- Consumption refills normal buffers. Only terminal/pause boundaries wait for
  presentation (or dataRendered during offline tests).
- Queue reset invalidates callbacks and occupancy together. It does not imply
  node flush: rapid resume intentionally retains queued fades. Node stop and
  graph routing resets remain explicit operations at their required boundaries.
- Stop publishes cancellation and silences the player before waiting for DSP.
  Worker drain and a second node flush prevent in-flight source PCM from leaking
  into a subsequent transport. Cancelled shuttle preparation is joined before
  handing processors to another owner.
- Pause intent is visible before its fade is audible. Completed pause position
  freezes only at presentation. Resume notification is generation-checked.
- Idle FX shares authoritative processors. Each processor's declared lookahead
  is drained independently, after its transport-playing edge. Downstream or
  parallel tails are not advanced by this drain.

## Graph render policy

| Mode | Timeline input | Routing PDC | Advance source | Cache |
| --- | --- | --- | --- | --- |
| timeline | Yes | Yes | Full block | Yes |
| fadeOut | Fading dry input | Yes | Remaining dry interval | No |
| fadeIn | Fading dry input | Yes | Full block | No |
| idleEffects | Silence | No | No | No |

Idle tails must not be delayed behind a newly cleared PDC queue. Genuine plug-in
voices/tails remain audible. Do not replace these rules with a universal reset
of processors or a meter noise gate.

Cache staging is synchronous and bounded. A discontinuity flushes the previous
batch; reads flush before accessing the file. Ready regions include retained RAM
and disk samples, but never skipped spans. Invalidation discards staging and
coverage together. No asynchronous writer or new audio producer is introduced.

## Regression gates

`--buffer-regression-test` includes core queue/clock/cache contracts, command
sequences with obsolete notifications, blocked Stop/shuttle return, pause/resume,
loop, recording alignment and routing tests. `--self-test` includes the same new
core and transition tests. `--multicore-test --no-benchmark` checks DSP equivalence
and worker ownership. Real plug-ins require `--plugin-buffer-test <bundle>` and
`--live-effects-ownership-test <bundle>`. The TONE3000 comparison uses its default
state, not an unspecified user model. UI/graphics tests remain a separate gate.

The cache write-count test proves batching (eight 512-frame blocks become one
write), not a particular playback CPU improvement. Full CPU improvements require
visible-window measurements on a representative project.

## Validation on 2026-11-12

- Release build signed with the existing Developer ID; signature verified.
- Buffer regression suite and full audio/editor self-test passed (including
  serial/parallel DSP equivalence and the new queue/clock/cache/transition tests).
- UI + graphics + playback-scroll integration passed.
- Installed CanaryVoiceTune and TONE3000 passed buffer-boundary, live-effects
  ownership, and full VST3 tests. Parallel/offline PCM matched serial PCM exactly.
- Canary: declared latency 19632 frames, additional startup onset 0 frames,
  stopped lookahead residual 0. TONE3000: the 500 ms parallel-latency comparison
  produced PCM error 0 and meter error 0 over 1.024 seconds after Stop.

The existing generic VST tests were corrected to prime declared latency before
checking output energy and to use an audible parameter/signal pair for Canary
(high-pass with an 80 Hz tone). Silence, concurrency and live parameter assertions
remain separate; none of their pass thresholds were relaxed.
