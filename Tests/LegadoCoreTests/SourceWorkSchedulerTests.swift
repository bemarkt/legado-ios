import Foundation
import Testing
@testable import LegadoCore

private actor SchedulerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
private actor SchedulerOrder {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

@Suite("Native source scheduler")
struct SourceWorkSchedulerTests {
    private func awaitCounts(_ scheduler: SourceWorkScheduler, active: Int, waiting: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let counts = await scheduler.counts
            if counts.active == active, counts.waiting == waiting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Scheduler did not reach expected active/waiting counts")
    }
    @Test func readingOvertakesQueuedBackgroundAndLeasesAlwaysRelease() async throws {
        let scheduler = SourceWorkScheduler(globalLimit: 1, perOriginLimit: 1)
        let gate = SchedulerGate(), order = SchedulerOrder()
        let first = Task { try await scheduler.withPermit(origin: "a", deadline: Date().addingTimeInterval(10)) { await gate.wait(); return 0 } }
        try await awaitCounts(scheduler, active: 1, waiting: 0)
        let background = Task { try await scheduler.withPermit(origin: "a", priority: .background, deadline: Date().addingTimeInterval(10)) { await order.add("background"); return 1 } }
        try await awaitCounts(scheduler, active: 1, waiting: 1)
        let foreground = Task { try await scheduler.withPermit(origin: "a", priority: .reading, deadline: Date().addingTimeInterval(10)) { await order.add("reading"); return 2 } }
        try await awaitCounts(scheduler, active: 1, waiting: 2)
        await gate.open()
        _ = try await first.value; _ = try await foreground.value; _ = try await background.value
        #expect(await order.values == ["reading", "background"])
        try await awaitCounts(scheduler, active: 0, waiting: 0)
        await #expect(throws: SourceDomainError.self) {
            try await scheduler.withPermit(origin: "a", deadline: Date().addingTimeInterval(5)) { () async throws -> Int in
                throw SourceDomainError(.unavailable, "Synthetic failure")
            }
        }
        try await awaitCounts(scheduler, active: 0, waiting: 0)
    }

    @Test func cancellationAndDeadlineRemoveQueuedWork() async throws {
        let scheduler = SourceWorkScheduler(globalLimit: 1, perOriginLimit: 1), gate = SchedulerGate()
        let first = Task { try await scheduler.withPermit(origin: "a", deadline: Date().addingTimeInterval(10)) { await gate.wait() } }
        try await awaitCounts(scheduler, active: 1, waiting: 0)
        let cancelled = Task { try await scheduler.withPermit(origin: "b", deadline: Date().addingTimeInterval(10)) { Issue.record("Cancelled work ran") } }
        try await awaitCounts(scheduler, active: 1, waiting: 1)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await #expect(throws: SourceDomainError.self) {
            try await scheduler.withPermit(origin: "b", deadline: Date().addingTimeInterval(0.05)) { Issue.record("Expired work ran") }
        }
        await gate.open(); try await first.value
        try await awaitCounts(scheduler, active: 0, waiting: 0)
    }

    @Test func blockedOriginDoesNotBlockOtherOrigins() async throws {
        let scheduler = SourceWorkScheduler(globalLimit: 2, perOriginLimit: 1), gate = SchedulerGate()
        let first = Task { try await scheduler.withPermit(origin: "a", deadline: Date().addingTimeInterval(10)) { await gate.wait() } }
        try await awaitCounts(scheduler, active: 1, waiting: 0)
        let same = Task { try await scheduler.withPermit(origin: "a", deadline: Date().addingTimeInterval(10)) { 1 } }
        try await awaitCounts(scheduler, active: 1, waiting: 1)
        let other = try await scheduler.withPermit(origin: "b", deadline: Date().addingTimeInterval(5)) { 2 }
        #expect(other == 2)
        await gate.open(); try await first.value
        #expect(try await same.value == 1)
        try await awaitCounts(scheduler, active: 0, waiting: 0)
    }
}
