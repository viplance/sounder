import AppKit
import Darwin

/// Process CPU, where 100% represents one logical CPU, as in Activity Monitor.
/// Sample cumulative CPU time, never enumerate threads or touch the audio queue.
struct ProcessCPUSampler {
    private var previous: (wall: Double, cpu: Double)?
    mutating func sample(wall: Double = ProcessInfo.processInfo.systemUptime, cpu: Double? = nil) -> Double {
        let total: Double
        if let cpu { total = cpu }
        else {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
            total = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        defer { previous = (wall, total) }
        guard let previous, wall > previous.wall, total >= previous.cpu else { return 0 }
        return max(0, (total - previous.cpu) / (wall - previous.wall) * 100)
    }
}

/// Disabled here means read-only transport status, not a dimmed value.
private final class BufferValueCell: NSButtonCell {
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        let colored = NSMutableAttributedString(attributedString: title)
        colored.addAttribute(.foregroundColor, value: accent, range: NSRange(location: 0, length: colored.length))
        colored.draw(in: frame)
        return frame
    }
}

final class PerformanceIndicators: NSStackView {
    let cpu = NSTextField(labelWithString: "0%")
    let buffer = PointerButton(title: "0%", target: nil, action: nil)
    var bufferValue: (() -> Double)?
    var bufferDescription: (() -> String)?
    var idleBufferText: (() -> String?)?
    var editBuffer: (() -> Void)?
    private var cpuSampleTime = -Double.infinity
    private var sampler = ProcessCPUSampler()
    private var timer: Timer?
    init() {
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .top; spacing = 14
        buffer.cell = BufferValueCell(textCell: "0%")
        cpu.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); cpu.textColor = accent; cpu.alignment = .right
        buffer.font = cpu.font; buffer.contentTintColor = accent; buffer.alignment = .right; buffer.isBordered = false
        buffer.target = self; buffer.action = #selector(editBufferSize)
        for (title, value) in [("CPU", cpu as NSView), ("BUFFER", buffer as NSView)] {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 9, weight: .semibold); label.textColor = .secondaryLabelColor
            value.setAccessibilityLabel(title + " percent")
            let holder = NSView(); holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(value); value.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([holder.widthAnchor.constraint(equalToConstant: title == "BUFFER" ? 76 : 52), holder.heightAnchor.constraint(equalToConstant: 28), value.trailingAnchor.constraint(equalTo: holder.trailingAnchor), value.centerYAnchor.constraint(equalTo: holder.centerYAnchor)])
            let column = NSStackView(views: [label, holder]); column.orientation = .vertical; column.alignment = .trailing; column.spacing = 8
            addArrangedSubview(column)
        }
        buffer.toolTip = "Prepared audio in the playback queue"
        cpu.toolTip = "Sounder CPU usage · 100% = one logical CPU"
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func editBufferSize() { if idleBufferText?() != nil { editBuffer?() } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); timer?.invalidate(); timer = nil
        guard window != nil else { return }
        _ = sampler.sample()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let window = self.window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return }
            self.refresh()
        }
        RunLoop.main.add(timer, forMode: .common); RunLoop.main.add(timer, forMode: .modalPanel); self.timer = timer
    }
    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - cpuSampleTime >= 0.25 {
            let cpuText = String(format: "%.0f%%", sampler.sample())
            if cpu.stringValue != cpuText { cpu.stringValue = cpuText }
            cpuSampleTime = now
        }
        let value = max(0, min(100, bufferValue?() ?? 0))
        let idle = idleBufferText?()
        let bufferText = idle ?? "\(Int(value))%"
        let description = idle != nil ? "Edit playback buffer size" : (bufferDescription?() ?? "Prepared audio in the playback queue")
        if buffer.isEnabled != (idle != nil) { buffer.isEnabled = idle != nil }
        if buffer.toolTip != description { buffer.toolTip = description }
        if buffer.title != bufferText {
            buffer.title = bufferText
            buffer.setAccessibilityLabel(idle != nil ? "Playback buffer: \(bufferText)" : "BUFFER percent")
        }
    }
    deinit { timer?.invalidate() }
}

final class PlaybackBufferDialog: NSObject, NSTextFieldDelegate {
    let alert = CompactSettingsAlert()
    let field: NSTextField
    let duration = NSTextField(labelWithString: "")
    private let sampleRate: Double
    init(frames: Int, sampleRate: Double) {
        self.sampleRate = sampleRate
        field = NSTextField(string: String(frames)); field.formatter = NumericInputFormatter(.integer)
        super.init()
        field.delegate = self
        alert.messageText = "Playback buffer"
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let title = NSTextField(labelWithString: "Samples")
        title.frame = NSRect(x: 0, y: 33, width: 100, height: 22); form.addSubview(title)
        field.frame = NSRect(x: 110, y: 31, width: 190, height: 26); field.setAccessibilityLabel("Playback buffer samples"); form.addSubview(field)
        duration.font = .systemFont(ofSize: 11); duration.textColor = .secondaryLabelColor
        duration.frame = NSRect(x: 0, y: 0, width: 300, height: 22); form.addSubview(duration)
        updateDuration()
        alert.accessoryView = form; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
    }
    func controlTextDidChange(_ notification: Notification) { updateDuration() }
    private func updateDuration() {
        duration.stringValue = Int(field.stringValue).map { PlaybackBufferSize.durationLabel(frames: $0, sampleRate: sampleRate) } ?? ""
    }
    func runModal() -> Int? {
        while alert.runModal() == .alertFirstButtonReturn {
            if let value = Int(field.stringValue), (try? PlaybackBufferSize.validate(value)) != nil { return value }
            alert.informativeText = "Enter 96–32768 samples."
        }
        return nil
    }
}

/// A short lock protects snapshots only; UI readers never wait for DSP/decoding.
final class AudioBufferFill {
    private let lock = NSLock()
    private var filled = 0
    private var capacity = 1
    private var generation: UInt64 = 0
    var percent: Double { lock.lock(); defer { lock.unlock() }; return min(100, max(0, Double(filled) / Double(capacity) * 100)) }
    func update(filled: Int, capacity: Int) { lock.lock(); self.filled = filled; self.capacity = max(1, capacity); lock.unlock() }
    func enqueue(frames: Int, capacity: Int) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        filled += frames; self.capacity = max(1, capacity)
        return generation
    }
    func consumed(frames: Int, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if self.generation == generation { filled = max(0, filled - frames) }
    }
    func reset() { lock.lock(); generation &+= 1; filled = 0; lock.unlock() }

}

final class PlaybackPreparation {
    private let lock = NSLock()
    private var cancelled = false
    private var done = 0.0
    private var total = 1.0
    private var phase = "Preparing audio"
    private var rendering = false
    var bufferPercent: Double { lock.lock(); defer { lock.unlock() }; return (rendering ? 40 : 0) + min(rendering ? 55 : 40, max(0, done / total * (rendering ? 55 : 40))) }
    var description: String { lock.lock(); defer { lock.unlock() }; return phase }
    func plan(frames: Double) { lock.lock(); total = max(1, frames); lock.unlock() }
    func advance(frames: Double) { lock.lock(); done += max(0, frames); lock.unlock() }
    func beginRendering(frames: Double) { lock.lock(); rendering = true; done = 0; total = max(1, frames); phase = "Preparing VST history and playback buffers"; lock.unlock() }
    func setPhase(_ phase: String) { lock.lock(); self.phase = phase; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { if isCancelled { throw CancellationError() } }
}
