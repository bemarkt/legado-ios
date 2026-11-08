import Foundation

/// Shared host admission control. A lease is always released, including failures and cancellation.
public actor SourceWorkScheduler {
    public enum Priority: Int, Sendable { case reading = 0, search = 1, background = 2 }
    private struct Pending {
        let id: UUID
        let origin: String
        let priority: Priority
        let continuation: CheckedContinuation<UUID, Error>
        let deadline: ContinuousClock.Instant
        let timer: Task<Void, Never>
    }
    private let globalLimit: Int
    private let perOriginLimit: Int
    private var waiting: [Pending] = []
    private var active: [UUID: String] = [:]
    public init(globalLimit: Int = 4, perOriginLimit: Int = 2) {
        self.globalLimit = max(1, globalLimit); self.perOriginLimit = max(1, perOriginLimit)
    }
    public func withPermit<T: Sendable>(origin: String, priority: Priority = .reading, deadline: Date,
                                        work: @Sendable () async throws -> T) async throws -> T {
        let interval = deadline.timeIntervalSinceNow
        guard interval.isFinite, interval > 0 else { throw SourceDomainError(.unavailable, "Request deadline expired") }
        let monotonic = ContinuousClock.now.advanced(by: .seconds(interval))
        return try await withPermit(origin: origin, priority: priority, deadline: monotonic, work: work)
    }
    public func withPermit<T: Sendable>(origin: String, priority: Priority = .reading, deadline: ContinuousClock.Instant,
                                        work: @Sendable () async throws -> T) async throws -> T {
        let id = try await acquire(origin: origin, priority: priority, deadline: deadline)
        defer { release(id) }
        try Task.checkCancellation()
        guard deadline > ContinuousClock.now else { throw SourceDomainError(.unavailable, "Request deadline expired in queue") }
        return try await work()
    }
    public var counts: (active: Int, waiting: Int) { (active.count, waiting.count) }
    private func acquire(origin: String, priority: Priority, deadline: ContinuousClock.Instant) async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard deadline > ContinuousClock.now else { continuation.resume(throwing: SourceDomainError(.unavailable, "Request deadline expired")); return }
                let timer = Task {
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    self.expire(id)
                }
                waiting.append(Pending(id: id, origin: origin, priority: priority, continuation: continuation, deadline: deadline, timer: timer))
                drain()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let request = waiting.remove(at: index)
        request.timer.cancel()
        request.continuation.resume(throwing: CancellationError())
        drain()
    }
    private func expire(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let request = waiting.remove(at: index)
        request.continuation.resume(throwing: SourceDomainError(.unavailable, "Request deadline expired in queue"))
        drain()
    }
    private func release(_ id: UUID) { active.removeValue(forKey: id); drain() }
    private func drain() {
        while active.count < globalLimit {
            let candidate = waiting.indices.filter { index in active.values.filter { $0 == waiting[index].origin }.count < perOriginLimit }
                .min { left, right in
                    waiting[left].priority.rawValue == waiting[right].priority.rawValue ? left < right : waiting[left].priority.rawValue < waiting[right].priority.rawValue
                }
            guard let index = candidate else { return }
            let request = waiting.remove(at: index)
            request.timer.cancel()
            if request.deadline <= ContinuousClock.now { request.continuation.resume(throwing: SourceDomainError(.unavailable, "Request deadline expired in queue")); continue }
            active[request.id] = request.origin
            request.continuation.resume(returning: request.id)
        }
    }
}
