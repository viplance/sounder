#pragma once
#include <cstdint>
// Minimal interoperable VST 2.x ABI declarations; no VST2 SDK is bundled.
namespace LegacyVST {
struct Effect;
using Callback = intptr_t (*)(Effect *, int32_t, int32_t, intptr_t, void *, float);
using Process = void (*)(Effect *, float **, float **, int32_t);
struct Effect {
    int32_t magic;
    Callback dispatch;
    Process process;
    void (*setParameter)(Effect *, int32_t, float);
    float (*getParameter)(Effect *, int32_t);
    int32_t numPrograms, numParams, numInputs, numOutputs, flags;
    intptr_t reserved1, reserved2;
    int32_t initialDelay, realQualities, offQualities;
    float ioRatio;
    void *object, *user;
    int32_t uniqueID, version;
    Process processReplacing;
    void (*processDoubleReplacing)(Effect *, double **, double **, int32_t);
    char future[56];
};
struct MidiEvent {
    int32_t type = 1, byteSize = 32, deltaFrames = 0, flags = 1;
    int32_t noteLength = 0, noteOffset = 0;
    uint8_t midiData[4] = {};
    int8_t detune = 0; uint8_t noteOffVelocity = 0, reserved1 = 0, reserved2 = 0;
};
struct MidiEvents { int32_t numEvents = 0; intptr_t reserved = 0; MidiEvent *events[2080] = {}; };
struct Rect { int16_t top, left, bottom, right; };
struct TimeInfo {
    double samplePos, sampleRate, nanoSeconds, ppqPos, tempo, barStartPos, cycleStartPos, cycleEndPos;
    int32_t timeSigNumerator, timeSigDenominator, smpteOffset, smpteFrameRate, samplesToNextClock, flags;
};
}
