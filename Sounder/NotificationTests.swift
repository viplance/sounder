import AppKit

func runNotificationTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw SounderError.message(message) }
        print("PASS: \(message)")
    }
    var clock = Date(timeIntervalSinceReferenceDate: 100)
    let center = ToastCenter(now: { clock })
    center.show("Project renamed", style: .success)
    let first = center.messages[0].id
    try check(center.messages[0].expiresAt == clock.addingTimeInterval(5), "Notifications last exactly five seconds")
    clock = clock.addingTimeInterval(1)
    center.hint(.nestTracks, "Drag tracks to nest")
    center.hint(.nestTracks, "Drag tracks to nest")
    center.hint(.selectFragments, "Shift click to multi select")
    center.hint(.selectFragments, "Shift click to multi select")
    center.show("Could not open audio", style: .error)
    try check(center.messages.map(\.text) == ["Project renamed", "Drag tracks to nest", "Shift click to multi select", "Could not open audio"], "New messages append below older messages; hints appear once")
    try check(center.messages.map(\.style) == [.success, .hint, .hint, .error], "Success, UX hints and errors use distinct notification styles")
    clock = clock.addingTimeInterval(3.99); center.expire()
    try check(center.messages.count == 4, "Messages remain visible for their full lifetime")
    clock = clock.addingTimeInterval(0.01); center.expire()
    try check(center.messages.count == 3 && !center.messages.contains { $0.id == first } && center.messages[0].text == "Drag tracks to nest", "Only expired messages disappear; remaining messages retain their order")
    clock = clock.addingTimeInterval(1); center.expire()
    center.hint(.nestTracks, "Drag tracks to nest"); center.hint(.selectFragments, "Shift click to multi select")
    try check(center.messages.isEmpty, "Expired hints do not reappear in the same session")
    center.show("Project renamed", style: .success); center.show("Project renamed", style: .success)
    try check(center.messages.count == 2, "Positive events are not limited to one per session")
    let secondSession = ToastCenter(now: { clock })
    secondSession.hint(.nestTracks, "Drag tracks to nest")
    try check(secondSession.messages.count == 1, "A new application session can show UX hints again")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SounderNotifications-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let editor = Editor(store: try AudioStore(directory: directory), notifications: secondSession)
    editor.renameProject("Session"); editor.undo(); editor.redo()
    editor.hint(.nestTracks, "Drag tracks to nest")
    try check(secondSession.messages.filter { $0.style == .hint }.count == 1 && secondSession.messages.contains { $0.text == "Project renamed" && $0.style == .success }, "Project edits and Undo do not reset session hints")
    let beforeRefresh = secondSession.messages.count
    editor.update(); editor.update()
    try check(secondSession.messages.count == beforeRefresh, "Ordinary UI refreshes produce no notifications")
    editor.error(SounderError.message("Audio unavailable"))
    try check(secondSession.messages.last?.style == .error, "Operational errors produce red notifications without a modal dialog")
    clock = clock.addingTimeInterval(5); secondSession.expire()
    let dirtyBeforeInvalidActions = editor.dirty
    for action in [editor.split, editor.trim, editor.deleteClips, editor.join] {
        action(); action()
        try check(secondSession.messages.count == 2 && secondSession.messages.allSatisfy { $0.style == .hint } && secondSession.messages[0].text == secondSession.messages[1].text, "Invalid fragment actions show a yellow notification on every click")
        clock = clock.addingTimeInterval(5); secondSession.expire()
        action()
        try check(secondSession.messages.count == 1 && editor.dirty == dirtyBeforeInvalidActions && editor.project.tracks[0].clips.isEmpty, "Fragment guidance reappears after expiration without modifying clips")
        clock = clock.addingTimeInterval(5); secondSession.expire()
    }
    editor.selectedTrack = nil
    editor.removeTrack(); editor.removeTrack()
    try check(secondSession.messages.count == 2 && secondSession.messages.allSatisfy { $0.text == "Select a track to delete" && $0.style == .hint } && editor.project.tracks.count == 1, "Delete track without an active track shows yellow guidance on every click")
    clock = clock.addingTimeInterval(5); secondSession.expire()
    editor.project.tracks = []
    editor.removeTrack()
    try check(secondSession.messages.count == 1 && secondSession.messages[0].style == .hint, "Delete track shows guidance when the project has no tracks")
}
