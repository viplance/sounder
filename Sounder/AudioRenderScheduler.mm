#import "AudioRenderScheduler.h"
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>
#include <pthread/qos.h>

namespace {
struct Node { int parent, children = 0; double cost = 1, priority = 1; };
struct Batch {
    std::vector<Node>& nodes;
    std::vector<int> pending;
    BOOL (^process)(NSInteger);
    size_t remaining;
    bool failed = false;
    std::condition_variable changed;
    Batch(std::vector<Node>& nodes, BOOL (^process)(NSInteger)) : nodes(nodes), process(process), remaining(nodes.size()) {
        pending.reserve(nodes.size());
        for (auto& node : nodes) pending.push_back(node.children);
    }
};
struct Task { Batch *batch; int index; };

class RenderPool {
    std::mutex mutex;
    std::condition_variable available;
    std::vector<Task> ready;
    std::vector<std::thread> workers;
    bool stopping = false;
    // Called with the pool lock held. Prefer expensive critical paths; a parent
    // is published only after all of its children have finished writing PCM.
    Task take(Batch *owner = nullptr) {
        auto best = ready.end();
        for (auto it = ready.begin(); it != ready.end(); ++it) {
            if (owner && it->batch != owner) continue;
            if (best == ready.end() || it->batch->nodes[it->index].priority > best->batch->nodes[best->index].priority) best = it;
        }
        if (best == ready.end()) return {nullptr, -1};
        auto task = *best; *best = ready.back(); ready.pop_back(); return task;
    }
    void execute(Task task) {
        auto& batch = *task.batch;
        bool skip;
        { std::lock_guard<std::mutex> lock(mutex); skip = batch.failed; }
        auto start = std::chrono::steady_clock::now();
        bool success = true;
        if (!skip) { @autoreleasepool { success = batch.process(task.index); } }
        auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        std::lock_guard<std::mutex> lock(mutex);
        auto& node = batch.nodes[task.index];
        if (!skip) node.cost = node.cost * 0.75 + elapsed * 0.25;
        batch.failed |= !success;
        if (node.parent >= 0 && --batch.pending[node.parent] == 0) {
            ready.push_back({&batch, node.parent}); available.notify_one();
        }
        --batch.remaining;
        batch.changed.notify_one();
    }
public:
    const int count;
    RenderPool() : count(std::max(1, (int)NSProcessInfo.processInfo.activeProcessorCount)) {
        ready.reserve(256);
        for (int i = 1; i < count; ++i) workers.emplace_back([this] {
            pthread_setname_np("Sounder DSP");
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
            for (;;) {
                Task task;
                {
                    std::unique_lock<std::mutex> lock(mutex);
                    available.wait(lock, [&] { return stopping || !ready.empty(); });
                    if (stopping) return;
                    task = take();
                }
                execute(task);
            }
        });
    }
    ~RenderPool() {
        { std::lock_guard<std::mutex> lock(mutex); stopping = true; }
        available.notify_all();
        for (auto& worker : workers) worker.join();
    }
    bool perform(std::vector<Node>& nodes, BOOL (^process)(NSInteger)) {
        Batch batch(nodes, process);
        std::unique_lock<std::mutex> lock(mutex);
        int leaves = 0;
        for (int i = 0; i < (int)nodes.size(); ++i) if (batch.pending[i] == 0) { ready.push_back({&batch, i}); ++leaves; }
        // One ready job belongs to the coordinator. Do not wake every core
        // for a graph that currently offers only two independent branches.
        for (int i = 1; i < std::min(leaves, count); ++i) available.notify_one();
        // The coordinator contributes DSP too. Workers never wait for other
        // nodes or recursively submit work, so a narrow graph cannot deadlock.
        while (batch.remaining) {
            auto task = take(&batch);
            if (task.batch) { lock.unlock(); execute(task); lock.lock(); }
            else batch.changed.wait(lock);
        }
        return !batch.failed;
    }
    // Process-lifetime workers must not be destroyed under a background render
    // during C++ static teardown. They sleep when idle; macOS reclaims them at exit.
    static RenderPool& shared() { static auto *pool = new RenderPool; return *pool; }
};
}

@implementation SNAudioRenderPlan {
    std::vector<Node> _nodes;
    NSInteger _width;
}
- (instancetype)initWithParents:(NSArray<NSNumber *> *)parents costs:(NSArray<NSNumber *> *)costs error:(NSError **)error {
    if (!(self = [super init])) return nil;
    for (NSUInteger i = 0; i < parents.count; ++i) {
        int parent = parents[i].intValue;
        if (parent < -1 || (parent != -1 && (parent <= (int)i || parent >= (int)parents.count))) {
            if (error) *error = [NSError errorWithDomain:@"Sounder.DSP" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid audio graph dependency"}];
            return nil;
        }
        // Initial cost estimates use seconds, as do measured block costs.
        _nodes.push_back({parent, 0, i < costs.count ? std::max(0.000001, costs[i].doubleValue) : 0.0001, 0});
    }
    for (auto& node : _nodes) if (node.parent >= 0) ++_nodes[node.parent].children;
    _width = std::count_if(_nodes.begin(), _nodes.end(), [](auto& node) { return node.children == 0; });
    return self;
}
- (NSInteger)workerCount { return MIN(_width, NSProcessInfo.processInfo.activeProcessorCount); }
- (BOOL)perform:(BOOL (NS_NOESCAPE ^)(NSInteger))process {
    double sum = 0, critical = 0;
    for (int i = (int)_nodes.size() - 1; i >= 0; --i) {
        auto& node = _nodes[i];
        node.priority = node.cost + (node.parent < 0 ? 0 : _nodes[node.parent].priority);
        sum += node.cost; critical = std::max(critical, node.priority);
    }
    // Tiny effects can cost less than a worker handoff. Continue measuring on
    // the serial path so a plug-in becoming expensive enables parallelism again.
    if (_width < 2 || NSProcessInfo.processInfo.activeProcessorCount < 2 || sum - critical < 0.00005) {
        for (NSInteger i = 0; i < (NSInteger)_nodes.size(); ++i) {
            auto start = std::chrono::steady_clock::now();
            if (!process(i)) return NO;
            auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
            _nodes[i].cost = _nodes[i].cost * 0.75 + elapsed * 0.25;
        }
        return YES;
    }
    return RenderPool::shared().perform(_nodes, process);
}
@end
