
import Foundation

public enum TaskResult<Success> {
    case success(Success)
    case failure(Error)
    case cancelled(isOriginTask: Bool)
    case updateDependency
    
    func withTaskCancellation(isOriginTask: Bool) -> Self {
        guard Task.isCancelled == false else {
            return .cancelled(isOriginTask: isOriginTask)
        }
        return self
    }
}

public struct RefreshContext {
    public let refreshAttempt: Int
}

public enum RefreshTaskResult<Dependency> {
    case success(Dependency)
    case failure(Error)
    case cancelled(isOriginTask: Bool)
    
    func withTaskCancellation(isOriginTask: Bool) -> Self {
        guard Task.isCancelled == false else {
            return .cancelled(isOriginTask: isOriginTask)
        }
        return self
    }
}

public enum FinalResult<Success> {
    case success(success: Success)
    case failure(error: Error, isOriginTask: Bool)
    case cancelled(isOriginTask: Bool)
    
    func withTaskCancellation(isOriginTask: Bool) -> Self {
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

public actor SmartQueue<Dependency> {
    private var dependency: Dependency?
    private var dependencyVersion: Int = 0
    private var queue: [QueuedTask] = []
    private var isRefreshing: Bool = false
    private var refreshAttempt: Int = 0
    private var refreshTask: (_ context: RefreshContext) async -> RefreshTaskResult<Dependency>
    private var isRunningQueue:Bool = false
    
    public init(dependency: Dependency? = nil, refreshTask: @escaping (_ context: RefreshContext) async -> RefreshTaskResult<Dependency>) {
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
        await self.run(forceRun: false, task: task)
    }
    
    private func run<Success>(
        forceRun: Bool = false,
        task: @escaping (Dependency) async -> TaskResult<Success>
    ) async -> FinalResult<Success> {
        if Task.isCancelled {
            return .cancelled(isOriginTask: true)
        }
        if isRefreshing == false || forceRun == true {
            // We're not refreshing or we're force running.
            
            let taskRunWithVersion = dependencyVersion
            
            if let dependency {
                // There is a dependency present
                switch await task(dependency)
                    .withTaskCancellation(isOriginTask: true)
                {
                    case let .success(success):
                        // The task was succesful
                        return .success(success: success)
                            .withTaskCancellation(isOriginTask: true)
                    case let .failure(failure):
                        // The task failed
                        return .failure(error: failure, isOriginTask: true)
                            .withTaskCancellation(isOriginTask: true)
                    case .cancelled:
                        // The task was cancelled
                        return .cancelled(isOriginTask: true)
                    case .updateDependency where isRefreshing,
                            .updateDependency where taskRunWithVersion < dependencyVersion:
                        // The task is currently refreshing
                        // The task was run with a lower dependency version
                        return await run(task: task)
                            .withTaskCancellation(isOriginTask: true)
                    case .updateDependency:
                        // Not refreshing
                        return await updateDependency(task: task)
                            .withTaskCancellation(isOriginTask: true)
                }
            } else {
                // There is no dependency present
                return await updateDependency(task: task)
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
                            let result = await self.run(forceRun: true, task: task)
                            continuation.resume(returning: result)
                        case let .failure(error):
                            continuation.resume(returning: .failure(error: error, isOriginTask: false))
                    }
                }))
            }
        }
    }
    
    private func updateDependency<Success>(
        task: @escaping (Dependency) async -> TaskResult<Success>
    ) async -> FinalResult<Success> {
        isRefreshing = true
        refreshAttempt += 1
        let context = RefreshContext(refreshAttempt: refreshAttempt + 1)
        let refreshResult = await refreshTask(context).withTaskCancellation(isOriginTask: true)
        switch refreshResult {
            case let .success(dependency):
                self.dependency = dependency
                dependencyVersion += 1
                refreshAttempt = 0
                for queuedTask in queue {
                    Task {
                        await queuedTask.run(input: .retry)
                    }
                }
                queue.removeAll()
                self.isRefreshing = false
                return await run(task: task)
                    .withTaskCancellation(isOriginTask: true)
            case let .failure(failure):
                for queuedTask in queue {
                    Task {
                        await queuedTask.run(input: .failure(failure))
                    }
                }
                queue.removeAll()
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
                self.isRefreshing = false
                return .cancelled(isOriginTask: true)
        }
    }
}

