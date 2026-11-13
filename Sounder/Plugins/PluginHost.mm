#import "PluginHost.h"
#include "LegacyVST.h"
#include "public.sdk/source/vst/hosting/module.h"
#include "public.sdk/source/vst/hosting/plugprovider.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"
#include "public.sdk/source/vst/hosting/processdata.h"
#include "public.sdk/source/vst/hosting/eventlist.h"
#include "public.sdk/source/common/memorystream.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include "pluginterfaces/vst/ivstmidicontrollers.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/base/funknownimpl.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <set>
#include <memory>
#include <vector>
#include <mutex>
#include <atomic>
using namespace Steinberg;
using namespace Steinberg::Vst;
namespace {
constexpr int blockSize = 512;

void fail(NSError **error, NSString *text) {
    if (error) *error = [NSError errorWithDomain:@"Sounder.Plugin" code:1 userInfo:@{NSLocalizedDescriptionKey: text}];
}
NSString *string16(const char16_t *text) { return [NSString stringWithCharacters:(const unichar *)text length:std::char_traits<char16_t>::length(text)]; }
NSData *streamData(MemoryStream& stream) { return [NSData dataWithBytes:stream.getData() length:stream.getSize()]; }
class Handler : public U::Implements<U::Directly<IComponentHandler>> {
public:
    std::map<ParamID, ParamValue> pending;
    std::mutex mutex;
    std::atomic<uint64_t> revision {0};
    void enqueue(ParamID id, ParamValue value) { std::lock_guard<std::mutex> lock(mutex); pending[id] = value; }
    std::map<ParamID, ParamValue> snapshot() { std::lock_guard<std::mutex> lock(mutex); return pending; }
    std::map<ParamID, ParamValue> drain() { std::lock_guard<std::mutex> lock(mutex); auto result = std::move(pending); pending.clear(); return result; }
    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID id, ParamValue value) override { enqueue(id, value); ++revision; return kResultOk; }
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32) override { return kResultOk; }
};
class Frame : public U::Implements<U::Directly<IPlugFrame>> {
public:
    __weak NSView *parent = nil;
    tresult PLUGIN_API resizeView(IPlugView *view, ViewRect *size) override {
        if (!parent || !size || size->getWidth() <= 0 || size->getHeight() <= 0) return kInvalidArgument;
        [parent setFrameSize:NSMakeSize(size->getWidth(), size->getHeight())];
        if (parent.window) [parent.window setContentSize:NSMakeSize(size->getWidth(), size->getHeight())];
        return view->onSize(size);
    }
};
class HostContext : public HostApplication {
    tresult PLUGIN_API getName(String128 name) override { const char16_t *text = u"Sounder"; std::copy(text, text + 8, name); return kResultOk; }
};
// Pass each host's context explicitly; concurrent preparation must not race
// through the SDK test helper's process-global PluginContextFactory.
class ContextPlugProvider : public PlugProvider {
public:
    using PlugProvider::PlugProvider;
    bool initializeWithContext(FUnknown *host) { return setupPlugin(host); }
};
struct Engine {
    double rate;
    std::recursive_mutex mutex;
    int streamingChannels = 0;
    int64 streamingPosition = 0;
    VST3::Hosting::Module::Ptr module;
    IPtr<HostContext> context = owned(new HostContext());
    IPtr<ContextPlugProvider> provider;
    IPtr<IComponent> component;
    IPtr<IEditController> controller;
    IPtr<IAudioProcessor> processor;
    IPtr<Handler> handler = owned(new Handler());
    IPtr<Frame> frame = owned(new Frame());
    IPtr<IPlugView> view;
    HostProcessData buffers;
    ParameterChanges changes;
    EventList events {4096};
    bool heldNotes[16][128] {};
    struct Midi { uint8_t status, data1, data2; };
    std::mutex midiMutex;
    std::vector<Midi> pendingMIDI;
    bool midiPanic = false, midiInput = false, instrument = false, transportPlaying = true;
    int64 continuousPosition = 0;
    void enqueueMIDI(uint8_t status, uint8_t data1, uint8_t data2) {
        std::lock_guard<std::mutex> lock(midiMutex);
        if (pendingMIDI.size() >= 2048) { pendingMIDI.clear(); midiPanic = true; }
        pendingMIDI.push_back({status, uint8_t(data1 & 127), uint8_t(data2 & 127)});
    }
    std::vector<Midi> drainMIDI() {
        std::lock_guard<std::mutex> lock(midiMutex);
        std::vector<Midi> result; result.swap(pendingMIDI);
        if (midiPanic) { for (int ch = 0; ch < 16; ++ch) result.insert(result.begin(), {uint8_t(0xB0 | ch), 123, 0}); midiPanic = false; }
        return result;
    }
    ProcessContext clock {};
    CFBundleRef legacyBundle = nullptr;
    LegacyVST::Effect *legacy = nullptr;
    LegacyVST::TimeInfo legacyClock {};
    __weak NSView *legacyParent = nil;
    bool legacyEditorOpen = false, active = false, processing = false;
    std::vector<std::vector<float>> legacyInputs, legacyOutputs;
    std::vector<float *> inputPointers, outputPointers;
    std::string classID, name;
    Engine(double sampleRate) : rate(sampleRate) { legacyClock.sampleRate = rate; legacyClock.tempo = 120; legacyClock.timeSigNumerator = 4; legacyClock.timeSigDenominator = 4; legacyClock.flags = (1 << 10) | (1 << 13); }
    ~Engine() {
        closeEditor();
        if (legacy) { legacy->dispatch(legacy, 72, 0, 0, nullptr, 0); legacy->dispatch(legacy, 12, 0, 0, nullptr, 0); legacy->dispatch(legacy, 1, 0, 0, nullptr, 0); }
        if (legacyBundle) CFRelease(legacyBundle);
        if (processor && processing) processor->setProcessing(false);
        if (component && active) component->setActive(false);
        if (controller) controller->setComponentHandler(nullptr);
        processor = nullptr; controller = nullptr; component = nullptr; provider = nullptr;
    }
    void closeEditor() {
        if (view) { view->removed(); view->setFrame(nullptr); view = nullptr; }
        frame->parent = nil;
        if (legacyEditorOpen) { legacy->dispatch(legacy, 15, 0, 0, nullptr, 0); legacyEditorOpen = false; }
        legacyParent = nil;
    }
    static intptr_t legacyHost(LegacyVST::Effect *effect, int32_t op, int32_t index, intptr_t value, void *ptr, float opt) {
        auto *self = effect ? static_cast<Engine *>(effect->user) : nullptr;
        switch (op) {
            case 0: if (self) ++self->handler->revision; return 1;
            case 42: return 1; // UI/latency refresh is not a parameter edit
            case 1: return 2400; // host ABI version, including before effect exists
            case 2: return effect ? effect->uniqueID : 0;
            case 7: return self ? reinterpret_cast<intptr_t>(&self->legacyClock) : 0;
            case 16: return self ? self->rate : 48000;
            case 17: return blockSize;
            case 23: return 2; // process in realtime mode on the render worker
            case 32: if (ptr) std::strcpy((char *)ptr, "Sounder"); return 1;
            case 33: if (ptr) std::strcpy((char *)ptr, "Sounder"); return 1;
            case 34: return 1000;
            case 37: if (ptr) { std::string capability((char *)ptr); return capability == "sizeWindow" || capability == "sendVstTimeInfo" || capability == "startStopProcess" || capability == "sendVstEvents" || capability == "sendVstMidiEvent"; } return 0;
            case 15: if (self && self->legacyParent && index > 0 && value > 0) { [self->legacyParent setFrameSize:NSMakeSize(index, value)]; [self->legacyParent.window setContentSize:NSMakeSize(index, value)]; return 1; } return 0;
            case 38: return 1; // English
            default: return 0;
        }
    }
    bool loadLegacy(NSString *path, NSError **error) {
        // macOS plug-ins register process-global ObjC classes. Keep modules loaded for
        // the process lifetime, and never unload code while another instance uses it.
        static auto *bundles = new std::map<std::string, CFBundleRef>();
        auto found = bundles->find(path.UTF8String);
        if (found != bundles->end()) legacyBundle = (CFBundleRef)CFRetain(found->second);
        else {
            legacyBundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)[NSURL fileURLWithPath:path]);
            if (legacyBundle) (*bundles)[path.UTF8String] = (CFBundleRef)CFRetain(legacyBundle);
        }
        if (!legacyBundle || !CFBundleLoadExecutable(legacyBundle)) { fail(error, @"Cannot load VST. It must support Apple Silicon (arm64)."); return false; }
        using Entry = LegacyVST::Effect *(*)(LegacyVST::Callback);
        auto entry = (Entry)CFBundleGetFunctionPointerForName(legacyBundle, CFSTR("VSTPluginMain"));
        if (!entry) entry = (Entry)CFBundleGetFunctionPointerForName(legacyBundle, CFSTR("main_macho"));
        if (!entry) { fail(error, @"This bundle has no VST entry point."); return false; }
        auto *effect = entry(legacyHost);
        if (!effect || effect->magic != 0x56737450 || !effect->dispatch) { fail(error, @"Invalid VST effect."); return false; }
        legacy = effect; legacy->user = this;
        legacy->dispatch(legacy, 0, 0, 0, nullptr, 0);
        if (legacy->numInputs < 0 || legacy->numInputs > 64 || legacy->numOutputs < 1 || legacy->numOutputs > 64 || !legacy->processReplacing) { fail(error, @"The VST plug-in needs float processing and an audio output."); return false; }
        instrument = (legacy->flags & (1 << 8)) != 0;
        midiInput = instrument || legacy->dispatch(legacy, 51, 0, 0, (void *)"receiveVstMidiEvent", 0) > 0;
        legacy->dispatch(legacy, 10, 0, 0, nullptr, rate);
        legacy->dispatch(legacy, 11, 0, blockSize, nullptr, 0);
        // Cocoa editor support, as specified by VST 2.4's Cockos extension.
        legacy->dispatch(legacy, 62, 0, 0, (void *)"hasCockosViewAsConfig", 0);
        name = path.lastPathComponent.stringByDeletingPathExtension.UTF8String;
        classID = std::to_string(legacy->uniqueID);
        return true;
    }
    bool loadVST3(NSString *path, NSString *identifier, NSError **error) {
        std::string message;
        static auto *modules = new std::map<std::string, VST3::Hosting::Module::Ptr>();
        static std::mutex modulesMutex;
        {
            std::lock_guard<std::mutex> lock(modulesMutex);
            auto found = modules->find(path.UTF8String);
            if (found != modules->end()) module = found->second;
        }
        if (!module) {
            // Module entry can initialize process-wide Cocoa/JUCE event handling.
            // Only first load belongs on the UI thread; DSP setup/rendering and
            // subsequent instances stay on their preparation/audio workers.
            auto load = [&] {
                std::lock_guard<std::mutex> lock(modulesMutex);
                auto found = modules->find(path.UTF8String);
                if (found != modules->end()) module = found->second;
                else {
                    module = VST3::Hosting::Module::create(path.UTF8String, message);
                    if (module) (*modules)[path.UTF8String] = module;
                }
            };
            if ([NSThread isMainThread]) load();
            else dispatch_sync(dispatch_get_main_queue(), ^{ load(); });
        }
        if (!module) { fail(error, [NSString stringWithFormat:@"Cannot load VST3: %s", message.c_str()]); return false; }
        auto factory = module->getFactory(); factory.setHostContext(context);
        for (const auto& info : factory.classInfos()) {
            if (info.category() != kVstAudioEffectClass) continue;
            if (identifier.length && info.ID().toString() != identifier.UTF8String) continue;
            instrument = info.subCategoriesString().find("Instrument") != std::string::npos;
            provider = owned(new ContextPlugProvider(factory, info, true));
            if (!provider->initializeWithContext(context)) { fail(error, @"VST3 initialization failed."); return false; }
            component = provider->getComponentPtr(); controller = provider->getControllerPtr();
            midiInput = component->getBusCount(kEvent, kInput) > 0;
            processor = FUnknownPtr<IAudioProcessor>(component);
            name = info.name(); classID = info.ID().toString(); break;
        }
        if (!component || !processor) { fail(error, @"No compatible VST3 processor found in this bundle."); return false; }
        if (processor->canProcessSampleSize(kSample32) != kResultOk) { fail(error, @"This effect does not support 32-bit float audio."); return false; }
        if (controller) {
            controller->setComponentHandler(handler);
            MemoryStream state;
            if (component->getState(&state) == kResultOk) { state.seek(0, IBStream::kIBSeekSet, nullptr); controller->setComponentState(&state); }
        }
        return true;
    }
    bool restore(NSData *state, NSError **error) {
        if (!state.length) return true;
        NSDictionary *saved = [NSPropertyListSerialization propertyListWithData:state options:NSPropertyListImmutable format:nil error:error];
        if (![saved isKindOfClass:NSDictionary.class]) return false;
        if (legacy) {
            NSData *chunk = saved[@"chunk"];
            if (chunk.length && (legacy->flags & (1 << 5))) legacy->dispatch(legacy, 24, 1, chunk.length, (void *)chunk.bytes, 0);
            NSArray *params = saved[@"parameters"];
            if (!chunk.length) for (NSInteger i = 0; i < MIN(params.count, legacy->numParams); ++i) legacy->setParameter(legacy, (int32_t)i, [params[i] floatValue]);
        } else {
            NSData *state = saved[@"component"];
            if (state.length) {
                MemoryStream stream((void *)state.bytes, state.length);
                if (component->setState(&stream) != kResultOk) { fail(error, @"VST3 could not restore its saved state."); return false; }
                stream.seek(0, IBStream::kIBSeekSet, nullptr); if (controller) controller->setComponentState(&stream);
            }
            NSData *ctrl = saved[@"controller"];
            if (ctrl.length && controller) { MemoryStream stream((void *)ctrl.bytes, ctrl.length); controller->setState(&stream); }
            // Complete component state is authoritative. Only edits still queued
            // for DSP at capture time may override it in the current format.
            NSDictionary *params = [saved[@"version"] integerValue] >= 2 && state.length ? saved[@"pendingParameters"] : saved[@"parameters"];
            for (NSString *key in params) { auto id = (ParamID)key.longLongValue; double value = [params[key] doubleValue]; if (controller) controller->setParamNormalized(id, value); handler->enqueue(id, value); }
        }
        return true;
    }
    bool prepare(int channels, NSError **error) {
        inputPointers.clear(); outputPointers.clear();
        if (legacy) {
            legacyInputs.assign(legacy->numInputs, std::vector<float>(blockSize)); legacyOutputs.assign(legacy->numOutputs, std::vector<float>(blockSize));
            for (auto& channel : legacyInputs) inputPointers.push_back(channel.data());
            for (auto& channel : legacyOutputs) outputPointers.push_back(channel.data());
            legacy->dispatch(legacy, 12, 0, 1, nullptr, 0); legacy->dispatch(legacy, 71, 0, 0, nullptr, 0); return true;
        }
        const int ins = component->getBusCount(kAudio, kInput), outs = component->getBusCount(kAudio, kOutput);
        if (ins < 0 || outs < 1 || ins > 64 || outs > 64) { fail(error, @"The plug-in has no usable audio input/output."); return false; }
        // Negotiate the project layout. If unsupported, adapt through the effect's
        // original layout (e.g. a mono-only effect on a stereo project).
        std::vector<SpeakerArrangement> originalInputs(ins), originalOutputs(outs);
        for (int i = 0; i < ins; ++i) processor->getBusArrangement(kInput, i, originalInputs[i]);
        for (int i = 0; i < outs; ++i) processor->getBusArrangement(kOutput, i, originalOutputs[i]);
        auto inputs = originalInputs, outputs = originalOutputs;
        outputs[0] = channels == 1 ? SpeakerArr::kMono : SpeakerArr::kStereo;
        if (ins > 0) inputs[0] = outputs[0];
        if (processor->setBusArrangements(inputs.data(), ins, outputs.data(), outs) != kResultOk)
            processor->setBusArrangements(originalInputs.data(), ins, originalOutputs.data(), outs);
        // Auxiliary buses receive silence.
        for (auto direction : {kInput, kOutput}) {
            for (int bus = 0; bus < component->getBusCount(kAudio, direction); ++bus) component->activateBus(kAudio, direction, bus, bus == 0);
            for (int bus = 0; bus < component->getBusCount(kEvent, direction); ++bus) component->activateBus(kEvent, direction, bus, direction == kInput && bus == 0);
        }
        ProcessSetup setup {kRealtime, kSample32, blockSize, rate};
        if (processor->setupProcessing(setup) != kResultOk) { fail(error, @"VST3 rejected the audio processing configuration."); return false; }
        if (!buffers.prepare(*component, blockSize, kSample32) || (ins > 0 && buffers.inputs[0].numChannels < 1) || buffers.outputs[0].numChannels < 1) { fail(error, @"VST3 audio buffers could not be configured."); return false; }
        if (component->setActive(true) != kResultOk) { fail(error, @"VST3 could not be activated."); return false; }
        active = true;
        // setProcessing is optional for some older effects.
        processor->setProcessing(true); processing = true;
        clock.sampleRate = rate; clock.tempo = 120; clock.timeSigNumerator = 4; clock.timeSigDenominator = 4;
        clock.state = ProcessContext::kPlaying | ProcessContext::kContTimeValid | ProcessContext::kTempoValid | ProcessContext::kTimeSigValid | ProcessContext::kProjectTimeMusicValid;
        return true;
    }
    bool block(const std::vector<std::vector<float>>& input, std::vector<std::vector<float>>& output, int count, int64 position, NSError **error) {
        auto feed = [&](float *target, int channel, int busChannels) {
            for (int i = 0; i < count; ++i) {
                if (busChannels == 1 && input.size() == 2) target[i] = (input[0][i] + input[1][i]) * 0.5f;
                else target[i] = channel < 2 ? input[std::min((size_t)channel, input.size() - 1)][i] : 0;
            }
        };
        auto collect = [&](float **source, int channels, uint64 silenceFlags) {
            for (int i = 0; i < count; ++i) {
                auto sample = [&](int channel) { return (silenceFlags & (uint64(1) << channel)) ? 0.0f : source[channel][i]; };
                if (output.size() == 1) output[0][i] = channels > 1 ? (sample(0) + sample(1)) * 0.5f : sample(0);
                else { output[0][i] = sample(0); output[1][i] = sample(channels > 1 ? 1 : 0); }
            }
        };
        auto midi = drainMIDI();
        if (legacy) {
            legacyClock.samplePos = position; legacyClock.ppqPos = double(position) / rate * legacyClock.tempo / 60;
            legacyClock.flags = (legacyClock.flags & ~2) | (transportPlaying ? 2 : 0);
            if (!midi.empty()) {
                LegacyVST::MidiEvents list; std::vector<LegacyVST::MidiEvent> messages(midi.size());
                list.numEvents = int32_t(std::min(size_t(2080), midi.size()));
                for (int i = 0; i < list.numEvents; ++i) {
                    messages[i].midiData[0] = midi[i].status; messages[i].midiData[1] = midi[i].data1; messages[i].midiData[2] = midi[i].data2;
                    list.events[i] = &messages[i];
                }
                legacy->dispatch(legacy, 25, 0, 0, &list, 0);
            }
            for (int ch = 0; ch < legacy->numInputs; ++ch) feed(legacyInputs[ch].data(), ch, legacy->numInputs);
            for (auto& channel : legacyOutputs) std::fill(channel.begin(), channel.end(), 0);
            legacy->processReplacing(legacy, inputPointers.data(), outputPointers.data(), count);
            collect(outputPointers.data(), legacy->numOutputs, 0);
            return true;
        }
        for (int bus = 0; bus < buffers.numInputs; ++bus) {
            auto& b = buffers.inputs[bus]; b.silenceFlags = bus == 0 ? 0 : HostProcessData::kAllChannelsSilent;
            for (int ch = 0; ch < b.numChannels; ++ch) {
                std::fill(b.channelBuffers32[ch], b.channelBuffers32[ch] + count, 0);
                if (bus == 0) feed(b.channelBuffers32[ch], ch, b.numChannels);
            }
        }
        for (int bus = 0; bus < buffers.numOutputs; ++bus) { auto& b = buffers.outputs[bus]; b.silenceFlags = 0; for (int ch = 0; ch < b.numChannels; ++ch) std::fill(b.channelBuffers32[ch], b.channelBuffers32[ch] + count, 0); }
        changes.clearQueue();
        for (const auto& pair : handler->drain()) { int32 index = 0; auto *queue = changes.addParameterData(pair.first, index); queue->addPoint(0, pair.second, index); }
        events.clear();
        FUnknownPtr<IMidiMapping> mapping(controller);
        for (const auto& message : midi) {
            const int channel = message.status & 15, type = message.status & 0xF0;
            Event event {}; event.busIndex = 0; event.sampleOffset = 0; event.flags = Event::kIsLive;
            if (type == 0x90 && message.data2 > 0) {
                event.type = Event::kNoteOnEvent; event.noteOn.channel = channel; event.noteOn.pitch = message.data1;
                event.noteOn.velocity = message.data2 / 127.f; event.noteOn.noteId = -1; events.addEvent(event); heldNotes[channel][message.data1] = true;
            } else if (type == 0x80 || type == 0x90) {
                event.type = Event::kNoteOffEvent; event.noteOff.channel = channel; event.noteOff.pitch = message.data1;
                event.noteOff.velocity = message.data2 / 127.f; event.noteOff.noteId = -1; events.addEvent(event); heldNotes[channel][message.data1] = false;
            } else if (type == 0xA0) {
                event.type = Event::kPolyPressureEvent; event.polyPressure.channel = channel; event.polyPressure.pitch = message.data1;
                event.polyPressure.pressure = message.data2 / 127.f; event.polyPressure.noteId = -1; events.addEvent(event);
            } else if (type == 0xB0 && (message.data1 == 123 || message.data1 == 120)) {
                for (int pitch = 0; pitch < 128; ++pitch) if (heldNotes[channel][pitch]) {
                    event.type = Event::kNoteOffEvent; event.noteOff.channel = channel; event.noteOff.pitch = pitch;
                    event.noteOff.velocity = 0; event.noteOff.noteId = -1; events.addEvent(event); heldNotes[channel][pitch] = false;
                }
            }
            if (mapping) {
                int controller = type == 0xB0 ? message.data1 : type == 0xE0 ? kPitchBend : type == 0xD0 ? kAfterTouch : -1;
                ParamID id;
                if (controller >= 0 && mapping->getMidiControllerAssignment(0, channel, controller, id) == kResultOk) {
                    const double value = type == 0xE0 ? (message.data1 + 128 * message.data2) / 16383.0 : (type == 0xD0 ? message.data1 : message.data2) / 127.0;
                    int32 index = 0; auto *queue = changes.addParameterData(id, index); queue->addPoint(0, value, index);
                }
            }
        }
        clock.state = (clock.state & ~ProcessContext::kPlaying) | (transportPlaying ? ProcessContext::kPlaying : 0);
        clock.projectTimeSamples = position; clock.continousTimeSamples = continuousPosition;
        clock.projectTimeMusic = double(position) / rate * clock.tempo / 60;
        continuousPosition += count;
        buffers.numSamples = count; buffers.processMode = kRealtime; buffers.processContext = &clock;
        buffers.inputParameterChanges = &changes; buffers.inputEvents = &events;
        auto result = processor->process(buffers);
        if (result != kResultOk) { fail(error, @"VST3 audio processing failed."); return false; }
        auto& bus = buffers.outputs[0];
        collect(bus.channelBuffers32, bus.numChannels, bus.silenceFlags);
        return true;
    }
};
}
@implementation SNPluginHost { std::unique_ptr<Engine> _engine; }
- (instancetype)initWithPath:(NSString *)path classID:(NSString *)classID state:(NSData *)state error:(NSError **)error {
    return [self initWithPath:path classID:classID state:state sampleRate:48000 error:error];
}
- (instancetype)initWithPath:(NSString *)path classID:(NSString *)classID state:(NSData *)state sampleRate:(double)sampleRate error:(NSError **)error {
    if (!(self = [super init])) return nil;
    if (!std::isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 192000) { fail(error, @"Unsupported plug-in sample rate."); return nil; }
    // Some plug-in frameworks bind their process-wide Cocoa message manager
    // when the first processor is constructed, rather than at module entry.
    // Bootstrap each bundle on AppKit's thread. Later instances and all DSP
    // preparation/rendering remain on workers. Callers must not block AppKit
    // while awaiting first-time background plug-in initialization.
    static std::mutex bootstrapMutex;
    static std::set<std::string> bootstrapped;
    const std::string bundlePath(path.UTF8String);
    bool ready;
    { std::lock_guard<std::mutex> lock(bootstrapMutex); ready = bootstrapped.count(bundlePath) != 0; }
    if (!ready && ![NSThread isMainThread]) {
        __block SNPluginHost *host = nil;
        __block NSError *failure = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            host = [[SNPluginHost alloc] initWithPath:path classID:classID state:state sampleRate:sampleRate error:&failure];
        });
        if (error) *error = failure;
        return host;
    }
    _engine = std::make_unique<Engine>(sampleRate);
    bool success = [path.pathExtension.lowercaseString isEqualToString:@"vst3"] ? _engine->loadVST3(path, classID, error) : _engine->loadLegacy(path, error);
    if (!success) return nil;
    { std::lock_guard<std::mutex> lock(bootstrapMutex); bootstrapped.insert(bundlePath); }
    if (classID.length && _engine->classID != classID.UTF8String) { fail(error, @"This is a different plug-in from the one saved in the project."); return nil; }
    if (!_engine->restore(state, error)) return nil;
    return self;
}
- (NSString *)pluginName { return [NSString stringWithUTF8String:_engine->name.c_str()]; }
- (NSString *)classID { return [NSString stringWithUTF8String:_engine->classID.c_str()]; }
- (NSInteger)latency { return _engine->legacy ? MAX(0, _engine->legacy->initialDelay) : _engine->processor->getLatencySamples(); }
- (NSInteger)tail {
    uint64 value = _engine->legacy ? _engine->legacy->dispatch(_engine->legacy, 52, 0, 0, nullptr, 0) : _engine->processor->getTailSamples();
    // VST2 uses 1 to mean no tail. Infinite/unknown tails are bounded to 10 seconds.
    if (_engine->legacy && value == 1) return 0;
    if (_engine->legacy && value == 0) return (NSInteger)(_engine->rate * 2);
    return MIN(value, (uint64)(_engine->rate * 10));
}
- (NSData *)processMono:(NSData *)audio error:(NSError **)error {
    return [self processAudio:audio channels:1 error:error];
}
- (NSData *)processAudio:(NSData *)audio channels:(NSInteger)channels error:(NSError **)error {
    return [self processAudio:audio channels:channels progress:^(double) {} cancelled:^BOOL { return NO; } error:error];
}
- (NSData *)processAudio:(NSData *)audio channels:(NSInteger)channels progress:(void (NS_NOESCAPE ^)(double))progress cancelled:(BOOL (NS_NOESCAPE ^)(void))cancelled error:(NSError **)error {
    std::lock_guard<std::recursive_mutex> lock(_engine->mutex);
    if ((channels != 1 && channels != 2) || audio.length % (sizeof(float) * channels)) { fail(error, @"Invalid audio channel data."); return nil; }
    if (!_engine->prepare((int)channels, error)) return nil;
    const size_t size = audio.length / sizeof(float) / channels;
    if (self.latency > (NSInteger)(_engine->rate * 30)) { fail(error, @"Plug-in latency exceeds the supported 30-second maximum."); return nil; }
    const size_t delay = self.latency;
    const size_t total = size + delay + self.tail;
    std::vector<float> result(total * channels);
    std::vector<std::vector<float>> in(channels, std::vector<float>(blockSize)), out(channels, std::vector<float>(blockSize));
    const auto *samples = (const float *)audio.bytes;
    for (size_t offset = 0; offset < total; offset += blockSize) {
        if (cancelled()) { if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]; return nil; }
        int count = (int)std::min((size_t)blockSize, total - offset);
        for (int ch = 0; ch < channels; ++ch) {
            std::fill(in[ch].begin(), in[ch].end(), 0);
            for (int i = 0; i < count && offset + i < size; ++i) in[ch][i] = samples[(offset + i) * channels + ch];
        }
        if (!_engine->block(in, out, count, offset, error)) return nil;
        for (int i = 0; i < count; ++i) for (int ch = 0; ch < channels; ++ch) result[(offset + i) * channels + ch] = std::isfinite(out[ch][i]) ? out[ch][i] : 0;
        progress(double(offset + count) / double(total));
    }
    return [NSData dataWithBytes:result.data() + delay * channels length:(total - delay) * channels * sizeof(float)];
}
- (uint64_t)editRevision { return _engine->handler->revision.load(); }
- (BOOL)acceptsMIDI { return _engine->midiInput; }
- (BOOL)isInstrument { return _engine->instrument; }
- (void)sendMIDIStatus:(uint8_t)status data1:(uint8_t)data1 data2:(uint8_t)data2 { _engine->enqueueMIDI(status, data1, data2); }
- (void)allNotesOff { for (int ch = 0; ch < 16; ++ch) { _engine->enqueueMIDI(0xB0 | ch, 64, 0); _engine->enqueueMIDI(0xB0 | ch, 123, 0); } }
- (void)setTransportPlaying:(BOOL)playing position:(int64_t)position tempo:(double)tempo {
    std::lock_guard<std::recursive_mutex> lock(_engine->mutex);
    _engine->transportPlaying = playing; _engine->streamingPosition = std::max(int64_t(0), position);
    _engine->clock.tempo = _engine->legacyClock.tempo = std::isfinite(tempo) ? std::clamp(tempo, 20., 300.) : 120.;
}
- (BOOL)ensureStreaming:(NSInteger)channels error:(NSError **)error {
    std::lock_guard<std::recursive_mutex> lock(_engine->mutex);
    if (_engine->streamingChannels == channels && (_engine->legacy || _engine->processing)) return YES;
    return [self beginStreaming:channels error:error];
}
- (BOOL)beginStreaming:(NSInteger)channels error:(NSError **)error {
    std::lock_guard<std::recursive_mutex> lock(_engine->mutex);
    if (channels != 1 && channels != 2) { fail(error, @"Invalid streaming channel count."); return NO; }
    if (_engine->legacy) { _engine->legacy->dispatch(_engine->legacy, 72, 0, 0, nullptr, 0); _engine->legacy->dispatch(_engine->legacy, 12, 0, 0, nullptr, 0); }
    if (_engine->processor && _engine->processing) _engine->processor->setProcessing(false);
    if (_engine->component && _engine->active) _engine->component->setActive(false);
    _engine->active = _engine->processing = false;
    if (!_engine->prepare((int)channels, error)) return NO;
    _engine->streamingChannels = (int)channels; _engine->streamingPosition = 0;
    _engine->continuousPosition = 0; _engine->transportPlaying = true;
    std::memset(_engine->heldNotes, 0, sizeof(_engine->heldNotes));
    return YES;
}
- (NSData *)processBlock:(NSData *)audio channels:(NSInteger)channels error:(NSError **)error {
    std::lock_guard<std::recursive_mutex> lock(_engine->mutex);
    if (channels != _engine->streamingChannels || channels < 1 || audio.length % (sizeof(float) * channels) || audio.length > blockSize * channels * sizeof(float)) { fail(error, @"Invalid streaming audio block."); return nil; }
    int count = (int)(audio.length / sizeof(float) / channels);
    std::vector<std::vector<float>> input(channels, std::vector<float>(blockSize)), output(channels, std::vector<float>(blockSize));
    const auto *samples = (const float *)audio.bytes;
    for (int i = 0; i < count; ++i) for (int ch = 0; ch < channels; ++ch) input[ch][i] = samples[i * channels + ch];
    if (!_engine->block(input, output, count, _engine->streamingPosition, error)) return nil;
    if (_engine->transportPlaying) _engine->streamingPosition += count;
    std::vector<float> result(count * channels);
    for (int i = 0; i < count; ++i) for (int ch = 0; ch < channels; ++ch) result[i * channels + ch] = std::isfinite(output[ch][i]) ? output[ch][i] : 0;
    return [NSData dataWithBytes:result.data() length:result.size() * sizeof(float)];
}
- (NSDictionary<NSString *, id> *)editorSnapshotSinceRevision:(uint64_t)revision parameterValues:(NSArray<NSNumber *> *)values {
    std::unique_lock<std::recursive_mutex> lock(_engine->mutex, std::try_to_lock);
    if (!lock.owns_lock()) return nil;
    NSMutableArray<NSNumber *> *current = [NSMutableArray array];
    for (NSDictionary *parameter in self.parameters) [current addObject:parameter[@"value"]];
    uint64_t edited = self.editRevision;
    NSMutableDictionary *snapshot = [@{@"values": current, @"revision": @(edited), @"latency": @(self.latency)} mutableCopy];
    if (edited != revision || ![values isEqualToArray:current]) {
        NSError *error = nil;
        NSData *state = [self saveState:&error];
        if (state) snapshot[@"state"] = state;
        else if (error) snapshot[@"error"] = error.localizedDescription;
    }
    return snapshot;
}
- (NSArray<NSDictionary<NSString *, id> *> *)parameters {
    std::lock_guard<std::recursive_mutex> lock(_engine->mutex);
    NSMutableArray *params = [NSMutableArray array];
    if (_engine->legacy) {
        for (int i = 0; i < std::min(4096, _engine->legacy->numParams); ++i) { char name[256] {}; _engine->legacy->dispatch(_engine->legacy, 8, i, 0, name, 0); [params addObject:@{@"index": @(i), @"name": [NSString stringWithUTF8String:name] ?: @"Parameter", @"value": @(_engine->legacy->getParameter(_engine->legacy, i))}]; }
    } else if (_engine->controller) {
        for (int i = 0; i < std::min(4096, _engine->controller->getParameterCount()); ++i) { ParameterInfo info {}; if (_engine->controller->getParameterInfo(i, info) != kResultOk || (info.flags & ParameterInfo::kIsReadOnly) || (info.flags & ParameterInfo::kIsHidden)) continue; [params addObject:@{@"index": @(info.id), @"name": string16(info.title), @"value": @(_engine->controller->getParamNormalized(info.id))}]; }
    }
    return params;
}
- (void)setParameter:(NSInteger)index value:(double)value {
    std::lock_guard<std::recursive_mutex> lock(_engine->mutex);
    ++_engine->handler->revision;
    value = std::clamp(value, 0.0, 1.0);
    if (_engine->legacy) { if (index >= 0 && index < _engine->legacy->numParams) _engine->legacy->setParameter(_engine->legacy, (int)index, value); }
    else if (_engine->controller) { _engine->controller->setParamNormalized((ParamID)index, value); _engine->handler->enqueue((ParamID)index, value); }
}
- (double)parameterValue:(NSInteger)index { return _engine->legacy ? _engine->legacy->getParameter(_engine->legacy, (int)index) : _engine->controller ? _engine->controller->getParamNormalized((ParamID)index) : 0; }
- (NSData *)saveState:(NSError **)error {
    std::lock_guard<std::recursive_mutex> lock(_engine->mutex);
    NSMutableDictionary *saved = [NSMutableDictionary dictionaryWithObject:@2 forKey:@"version"];
    if (_engine->legacy) {
        void *chunk = nullptr; auto *effect = _engine->legacy;
        if (effect->flags & (1 << 5)) { auto size = effect->dispatch(effect, 23, 1, 0, &chunk, 0); if (size > 0 && chunk) saved[@"chunk"] = [NSData dataWithBytes:chunk length:size]; else { fail(error, @"VST could not save its complete state."); return nil; } }
        NSMutableArray *params = [NSMutableArray array]; for (int i = 0; i < effect->numParams; ++i) [params addObject:@(effect->getParameter(effect, i))]; saved[@"parameters"] = params;
    } else {
        MemoryStream comp, ctrl;
        auto result = _engine->component->getState(&comp);
        if (result == kResultOk) saved[@"component"] = streamData(comp);
        else if (result != kNotImplemented) { fail(error, @"VST3 could not save its complete state."); return nil; }
        NSMutableDictionary *pending = [NSMutableDictionary dictionary];
        for (const auto& pair : _engine->handler->snapshot()) pending[[@(pair.first) stringValue]] = @(pair.second);
        saved[@"pendingParameters"] = pending;
        if (_engine->controller && _engine->controller->getState(&ctrl) == kResultOk) saved[@"controller"] = streamData(ctrl);
        NSMutableDictionary *params = [NSMutableDictionary dictionary];
        for (NSDictionary *p in self.parameters) { NSNumber *index = p[@"index"]; params[index.stringValue] = @([self parameterValue:index.integerValue]); }
        saved[@"parameters"] = params;
    }
    return [NSPropertyListSerialization dataWithPropertyList:saved format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
}
- (BOOL)attachEditor:(NSView *)parent {
    [self detachEditor];
    if (_engine->legacy) {
        auto *effect = _engine->legacy;
        if (!(effect->flags & 1)) return NO;
        LegacyVST::Rect *rect = nullptr; effect->dispatch(effect, 13, 0, 0, &rect, 0);
        if (!rect || rect->right <= rect->left || rect->bottom <= rect->top) return NO;
        [parent setFrameSize:NSMakeSize(rect->right - rect->left, rect->bottom - rect->top)];
        _engine->legacyParent = parent; effect->dispatch(effect, 14, 0, 0, (__bridge void *)parent, 0); _engine->legacyEditorOpen = true;
        return YES;
    }
    if (!_engine->controller) return NO;
    _engine->view = owned(_engine->controller->createView(ViewType::kEditor));
    auto view = _engine->view;
    if (!view || view->isPlatformTypeSupported(kPlatformTypeNSView) != kResultOk) { _engine->view = nullptr; return NO; }
    _engine->frame->parent = parent; view->setFrame(_engine->frame);
    ViewRect rect; if (view->getSize(&rect) == kResultOk) [parent setFrameSize:NSMakeSize(rect.getWidth(), rect.getHeight())];
    if (view->attached((__bridge void *)parent, kPlatformTypeNSView) != kResultOk) { view->setFrame(nullptr); _engine->view = nullptr; return NO; }
    view->onSize(&rect); return YES;
}
- (void)editorIdle { if (_engine->legacyEditorOpen) _engine->legacy->dispatch(_engine->legacy, 19, 0, 0, nullptr, 0); }
- (void)detachEditor { if (_engine) _engine->closeEditor(); }
@end
