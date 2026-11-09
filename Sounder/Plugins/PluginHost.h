#import "../AudioRenderScheduler.h"
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
// Objective-C surface keeps the VST C++ ABI out of Swift.
@interface SNPluginHost : NSObject
@property(nonatomic, readonly) NSString *pluginName;
@property(nonatomic, readonly) NSString *classID;
@property(nonatomic, readonly) NSInteger latency;
@property(nonatomic, readonly) NSInteger tail;
@property(nonatomic, readonly) BOOL acceptsMIDI;
@property(nonatomic, readonly) BOOL isInstrument;
- (BOOL)ensureStreaming:(NSInteger)channels error:(NSError **)error;
- (void)setTransportPlaying:(BOOL)playing position:(int64_t)position tempo:(double)tempo;
- (void)sendMIDIStatus:(uint8_t)status data1:(uint8_t)data1 data2:(uint8_t)data2;
- (void)allNotesOff;
@property(nonatomic, readonly) uint64_t editRevision;
- (BOOL)beginStreaming:(NSInteger)channels error:(NSError **)error;
- (nullable NSData *)processBlock:(NSData *)audio channels:(NSInteger)channels error:(NSError **)error;
- (nullable instancetype)initWithPath:(NSString *)path classID:(NSString *)classID state:(nullable NSData *)state error:(NSError **)error;
- (nullable instancetype)initWithPath:(NSString *)path classID:(NSString *)classID state:(nullable NSData *)state sampleRate:(double)sampleRate error:(NSError **)error;
- (nullable NSData *)processAudio:(NSData *)audio channels:(NSInteger)channels error:(NSError **)error;
- (nullable NSData *)processAudio:(NSData *)audio channels:(NSInteger)channels progress:(void (NS_NOESCAPE ^)(double))progress cancelled:(BOOL (NS_NOESCAPE ^)(void))cancelled error:(NSError **)error;
- (nullable NSData *)processMono:(NSData *)audio error:(NSError **)error;
- (nullable NSData *)saveState:(NSError **)error;
- (NSArray<NSDictionary<NSString *, id> *> *)parameters;
// UI polling must never wait on a slow processBlock/setupProcessing call.
- (nullable NSDictionary<NSString *, id> *)editorSnapshotSinceRevision:(uint64_t)revision parameterValues:(NSArray<NSNumber *> *)values NS_SWIFT_NAME(editorSnapshot(revision:values:));
- (void)setParameter:(NSInteger)index value:(double)value;
- (double)parameterValue:(NSInteger)index;
- (BOOL)attachEditor:(NSView *)parent;
- (void)detachEditor;
- (void)editorIdle;
@end
NS_ASSUME_NONNULL_END
