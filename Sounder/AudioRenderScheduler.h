#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Immutable forest, in child-before-parent order. A plan has one coordinator;
/// independent plans share the same bounded, sleeping worker pool.
@interface SNAudioRenderPlan : NSObject
- (nullable instancetype)initWithParents:(NSArray<NSNumber *> *)parents costs:(NSArray<NSNumber *> *)costs error:(NSError **)error;
- (BOOL)perform:(BOOL (NS_NOESCAPE ^)(NSInteger index))process;
@property(nonatomic, readonly) NSInteger workerCount;
@end
NS_ASSUME_NONNULL_END
