import Synchronization

/// A shared LIFO work queue for a fixed set of workers that also produce
/// work (subdirectories). `next` suspends when the queue is empty but other
/// workers are still busy, and returns nil once every worker is idle and no
/// work is left, or after `cancel`.
final class WorkQueue<Job: Sendable>: Sendable {
  private struct State {
    var jobs: [Job] = []
    /// Jobs handed out and not yet finished.
    var active = 0
    var waiters: [CheckedContinuation<Job?, Never>] = []
    var done = false
  }

  private let state: Mutex<State>

  init(_ jobs: [Job]) {
    state = Mutex(State(jobs: jobs.reversed()))
  }

  /// Adds jobs, handing them directly to waiting workers where possible.
  func push(_ jobs: some Collection<Job>) {
    guard !jobs.isEmpty else { return }
    var handoff: [(CheckedContinuation<Job?, Never>, Job)] = []
    state.withLock { s in
      guard !s.done else { return }
      var iterator = jobs.makeIterator()
      while !s.waiters.isEmpty, let job = iterator.next() {
        s.active += 1
        handoff.append((s.waiters.removeLast(), job))
      }
      while let job = iterator.next() { s.jobs.append(job) }
    }
    for (waiter, job) in handoff { waiter.resume(returning: job) }
  }

  private enum Decision {
    case job(Job)
    case finished([CheckedContinuation<Job?, Never>])
    case wait
  }

  /// Takes the next job. `finishedOne` reports that the caller completed the
  /// job it got from the previous call.
  func next(finishedOne: Bool) async -> Job? {
    let decision = state.withLock { s -> Decision in
      if finishedOne { s.active -= 1 }
      return Self.decide(&s)
    }
    switch decision {
    case .job(let job):
      return job
    case .finished(let waiters):
      for waiter in waiters { waiter.resume(returning: nil) }
      return nil
    case .wait:
      return await withCheckedContinuation { continuation in
        let recheck = state.withLock { s -> Decision in
          let d = Self.decide(&s)
          if case .wait = d { s.waiters.append(continuation) }
          return d
        }
        switch recheck {
        case .job(let job):
          continuation.resume(returning: job)
        case .finished(let waiters):
          continuation.resume(returning: nil)
          for waiter in waiters { waiter.resume(returning: nil) }
        case .wait:
          break
        }
      }
    }
  }

  private static func decide(_ s: inout State) -> Decision {
    if !s.done, let job = s.jobs.popLast() {
      s.active += 1
      return .job(job)
    }
    if s.done || s.active == 0 {
      s.done = true
      let waiters = s.waiters
      s.waiters = []
      return .finished(waiters)
    }
    return .wait
  }

  /// Drops all pending work and releases waiting workers (for `-q` or a
  /// closed output pipe).
  func cancel() {
    let waiters = state.withLock { s -> [CheckedContinuation<Job?, Never>] in
      s.done = true
      s.jobs.removeAll()
      let waiters = s.waiters
      s.waiters = []
      return waiters
    }
    for waiter in waiters { waiter.resume(returning: nil) }
  }
}
