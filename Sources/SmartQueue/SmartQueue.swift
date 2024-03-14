
import Foundation

/// This is the result of a task, when running tasks you need to return this struct.
public enum TaskResult<Success> {
    case success(Success)
    case failure(Error)
    case cancelled(isOriginTask: Bool)
    case refreshDependency
    
    internal func withTaskCancellation(isOriginTask: Bool) -> Self {
        guard Task.isCancelled == false else {
            return .cancelled(isOriginTask: isOriginTask)
        }
        return self
    }
}

/// The underlying reason for why a refresh was required.
public enum RefreshReason<Dependency> {
    case missingDependency
    case taskRequiredUpdate(dependency:Dependency)
}

/// Contains information for the refresh.
public struct RefreshContext<Dependency> {
    /// The refresh count, begins at 1 for the first refresh.
    public let refreshAttempt: Int
    
    /// The reason for the refresh occuring.
    public let reason:RefreshReason<Dependency>
}

/// The result of a refresh.
public enum RefreshTaskResult<Dependency> {
    case success(Dependency)
    case failure(Error)
    case cancelled(isOriginTask: Bool)
    
    internal func withTaskCancellation(isOriginTask: Bool) -> Self {
        guard Task.isCancelled == false else {
            return .cancelled(isOriginTask: isOriginTask)
        }
        return self
    }
}

/// The final result of a task->refresh->task.
public enum FinalResult<Success> {
    case success(success: Success)
    case failure(error: Error, isOriginTask: Bool)
    case cancelled(isOriginTask: Bool)
    
    internal func withTaskCancellation(isOriginTask: Bool) -> Self {
        guard Task.isCancelled == false else {
            return .cancelled(isOriginTask: isOriginTask)
        }
        return self
    }
}

extension FinalResult:Equatable where Success:Equatable {
    public static func == (lhs: FinalResult<Success>, rhs: FinalResult<Success>) -> Bool {
        switch (lhs,rhs) {
        case (.success(let left),.success(let right)):
            return left == right
        case (.failure(_, let left),.failure(_, let right)):
            return left == right
        case (.cancelled(let left),.cancelled(let right)):
            return left == right
        default:
            return false
        }
    }
}

private enum QueuedTaskInput {
    case retry
    case cancelled
    case failure(Error)
}

private struct QueuedTask {
    private let task: (_ input: QueuedTaskInput) async -> Void
    
    init(task: @escaping (_ input: QueuedTaskInput) async -> Void) {
        self.task = task
    }
    
    func run(input: QueuedTaskInput) async {
        await task(input)
    }
}

/// A queue that has two unique features:
/// - Provides a dependency for each running task
/// - Switches between serial and concurrent mode depending on how tasks behave
///
/// When you queue a task it has an input parameter which is generic. I'll refer to that as the "dependency".
/// The queue is generic over that type `Dependency`. A good way to understand it is that it could be
/// and access token for an OAuth flow. Since each network requests needs this for the authorization header
/// you can wrap each network call in this queue. And it's guaranteed that all tasks now will be provided with
/// an access token.
///
/// The default behaviour of the queue is concurrent.
///
/// When a task returns `TaskResult.refreshDependency` then the queue will switch to a serial mode.
/// In the serial mode it will re-queue all currently running tasks if they also return `TaskResult.refreshDependency`.
/// All new tasks will be queued immediately. Then the refresh task passed into the initialiser will get called
/// once - and only once. If a new dependency comes out of that then all the tasks will be run again.
public actor SmartQueue<Dependency> {
    private var dependency: Dependency?
    private var dependencyVersion: Int = 0
    private var queue: [QueuedTask] = []
    private var isRefreshing: Bool = false
    private var refreshAttempt: Int = 0
    private var refreshTask: (_ context: RefreshContext<Dependency>) async -> RefreshTaskResult<Dependency>
    private var isRunningQueue:Bool = false
    
    /// Creates a new SmartQueue.
    /// - Parameters:
    ///   - dependency: A predefined dependency value.
    ///   - refreshTask: A task showing how to refresh the dependency.
    public init(dependency: Dependency? = nil, refreshTask: @escaping (_ context: RefreshContext<Dependency>) async -> RefreshTaskResult<Dependency>) {
        self.dependency = dependency
        self.refreshTask = refreshTask
    }
    
    /// This is the main touch point. This method allows you to queue up tasks and let them be run. It will
    /// automatically queue tasks while refreshing, and will avoid all known race conditions.
    /// - Parameter task: The code that requires the dependency.
    /// - Returns: Returns a `FinalResult`.
    public func run<Success>(
        task: @escaping (Dependency) async -> TaskResult<Success>
    ) async -> FinalResult<Success> {
        await self.runInternal(task: task)
    }
    
    /// Manually set the dependency.
    /// - Parameter dependency: A new dependency or nil if you want to remove it.
    public func setDependency(_ dependency:Dependency?) async {
        self.dependency = dependency
    }
    
    private func runInternal<Success>(
        task: @escaping (Dependency) async -> TaskResult<Success>
    ) async -> FinalResult<Success> {
        if Task.isCancelled {
            return .cancelled(isOriginTask: true)
        }
        if isRefreshing == false {
            // We're not refreshing or we're force running.
            
            if let dependency {
                // There is a dependency present
                
                let taskRunWithVersion = dependencyVersion
                let taskRunWithDependency = dependency
                
                switch await task(dependency)
                    .withTaskCancellation(isOriginTask: true)
                {
                case let .success(success):
                    // The task was succesful
                    self.refreshAttempt = 0
                    return .success(success: success)
                        .withTaskCancellation(isOriginTask: true)
                case let .failure(failure):
                    // The task failed
                    self.refreshAttempt = 0
                    return .failure(error: failure, isOriginTask: true)
                        .withTaskCancellation(isOriginTask: true)
                case .cancelled:
                    // The task was cancelled
                    self.refreshAttempt = 0
                    return .cancelled(isOriginTask: true)
                case .refreshDependency where isRefreshing,
                        .refreshDependency where taskRunWithVersion < dependencyVersion:
                    // The task is currently refreshing
                    // The task was run with a lower dependency version
                    return await run(task: task)
                        .withTaskCancellation(isOriginTask: true)
                case .refreshDependency:
                    // Not refreshing
                    return await refreshDependency(
                        reason: .taskRequiredUpdate(dependency: taskRunWithDependency),
                        task: task)
                    .withTaskCancellation(isOriginTask: true)
                }
            } else {
                // There is no dependency present
                return await refreshDependency(
                    reason: .missingDependency,
                    task: task)
                .withTaskCancellation(isOriginTask: true)
            }
            
        } else {
            // We are currently refreshing so we store the task
            return await withCheckedContinuation { continuation in
                self.queue.append(QueuedTask(task: { input in
                    switch input {
                    case .cancelled:
                        continuation.resume(returning: .cancelled(isOriginTask: false))
                    case .retry:
                        let result = await self.run(task: task)
                        continuation.resume(returning: result)
                    case let .failure(error):
                        continuation.resume(returning: .failure(error: error, isOriginTask: false))
                    }
                }))
            }
        }
    }
    
    private func refreshDependency<Success>(
        reason: RefreshReason<Dependency>,
        task: @escaping (Dependency) async -> TaskResult<Success>
    ) async -> FinalResult<Success> {
        isRefreshing = true
        refreshAttempt += 1
        let context = RefreshContext(refreshAttempt: refreshAttempt, reason: reason)
        let refreshResult = await refreshTask(context).withTaskCancellation(isOriginTask: true)
        switch refreshResult {
        case let .success(dependency):
            self.dependency = dependency
            dependencyVersion += 1
            self.refreshAttempt = 0
            self.isRefreshing = false
            for queuedTask in queue {
                Task {
                    await queuedTask.run(input: .retry)
                }
            }
            queue.removeAll()
            return await run(task: task)
                .withTaskCancellation(isOriginTask: true)
        case let .failure(failure):
            for queuedTask in queue {
                Task {
                    await queuedTask.run(input: .failure(failure))
                }
            }
            queue.removeAll()
            self.refreshAttempt = 0
            self.isRefreshing = false
            return .failure(error: failure, isOriginTask: true)
                .withTaskCancellation(isOriginTask: true)
        case .cancelled:
            for queuedTask in queue {
                Task {
                    await queuedTask.run(input: .cancelled)
                }
            }
            queue.removeAll()
            self.refreshAttempt = 0
            self.isRefreshing = false
            return .cancelled(isOriginTask: true)
        }
    }
}


