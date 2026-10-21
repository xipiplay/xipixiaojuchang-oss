import Foundation

/// 同时只放 `limit` 个进去，多的排队（先来先放）。批量任务用它限制同一时间发出去的请求数。
/// 排队时被取消：直接退出排队、不占名额，也不会卡住后面的。
actor AsyncGate {
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) { available = max(1, limit) }

    /// 有空位就占一个、返回 true；没有就返回 false（不排队）
    func tryAcquire() -> Bool {
        guard available > 0 else { return false }
        available -= 1
        return true
    }

    /// 等到有空位并占一个。等的时候被取消会抛 `CancellationError`（这时没有占名额，不要 `release`）
    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append((id, continuation))
                // 取消可能赶在登记之前：登记完再看一眼，已经取消就立刻退出排队
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// 用完放回一个名额；有人在排队就直接交给最早的那个
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
