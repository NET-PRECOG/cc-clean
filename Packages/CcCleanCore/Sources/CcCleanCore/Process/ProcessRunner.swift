import Foundation

/// 命令执行规格。executablePath 必须为绝对路径（安全要求：不做 PATH 查找）。
public struct ProcessSpec: Sendable {

    public let executablePath: String
    public let arguments: [String]
    /// nil = 继承当前进程环境；非 nil = 全量替换（brew 等需固定环境时由调用方构造）。
    public let environment: [String: String]?
    /// 单路输出（stdout/stderr 各自）累计上限，超出后标记 truncated 并丢弃后续（保持排空管道）。
    public var outputLimit: Int
    /// 单次执行超时；到时先 SIGTERM，500ms 后仍存活则 SIGKILL。
    public var timeout: Duration

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        outputLimit: Int = 1_000_000,
        timeout: Duration = .seconds(30)
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.outputLimit = outputLimit
        self.timeout = timeout
    }
}

/// 命令执行结果。非零退出码不抛错，由调用方按业务语义处理（基线 6.3 风格：失败用返回值表达）。
public struct ProcessResult: Sendable, Equatable {

    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let truncated: Bool
    public let timedOut: Bool
    public let cancelled: Bool
    /// 是否由本 Runner 发起过 terminate/kill（超时或取消）。
    public let terminatedByRunner: Bool

    public var succeeded: Bool { exitCode == 0 }

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        truncated: Bool = false,
        timedOut: Bool = false,
        cancelled: Bool = false,
        terminatedByRunner: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.terminatedByRunner = terminatedByRunner
    }
}

public enum ProcessRunnerError: Error, Equatable {
    case executableNotFound(path: String)
    case launchFailed(path: String, underlying: String)
}

/// L1 唯一命令出口（基线 5.1 约束 2 / 5.2）。
/// 代码库中 `Process(` 只允许出现在本文件（scripts/check-redlines.sh 强制）。
public struct ProcessRunner: Sendable {

    public init() {}

    /// 执行命令。启动失败抛错；进程级失败（非零退出/超时/取消）全部通过返回值表达。
    public func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        let running = try RunningProcess(spec: spec)
        try running.start()

        // 与超时 watchdog 竞速；先完成者决定流程。
        enum Race: Sendable { case exited, timedOut }

        let outcome: Race = await withTaskGroup(of: Race.self) { group in
            group.addTask { await running.waitAndFinish(); return .exited }
            group.addTask {
                do { try await Task.sleep(for: spec.timeout) } catch { /* 被取消，立即结束 */ }
                return .timedOut
            }
            let first = (await group.next()) ?? .exited
            if first == .timedOut {
                running.terminate(reason: .timeout)
                await running.waitAndFinish()
            }
            group.cancelAll()
            return first
        }

        var cancelled = false
        if Task.isCancelled {
            cancelled = true
            running.terminate(reason: .cancelled)
            await running.waitAndFinish()
        } else {
            // 处理 race 期间到达的外部取消
            await withTaskCancellationHandler {
                _ = running
            } onCancel: {
                running.terminate(reason: .cancelled)
            }
            if running.consumeCancelledFlag() {
                cancelled = true
                await running.waitAndFinish()
            }
        }

        let (stdout, stderr, truncated, timedOut, terminated) = running.collectResult()
        _ = outcome
        return ProcessResult(
            exitCode: running.exitCode,
            stdout: stdout,
            stderr: stderr,
            truncated: truncated,
            timedOut: timedOut,
            cancelled: cancelled,
            terminatedByRunner: terminated
        )
    }
}

/// 终止原因标记（决定结果中的 timedOut / cancelled）。
private final class TerminationFlags: @unchecked Sendable {
    enum Reason { case timeout, cancelled }
    private let lock = NSLock()
    private var _timedOut = false
    private var _cancelled = false

    func mark(_ reason: Reason) {
        lock.lock(); defer { lock.unlock() }
        switch reason {
        case .timeout: _timedOut = true
        case .cancelled: _cancelled = true
        }
    }

    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
}

/// 输出累计盒：线程安全，超限后丢弃后续并标记 truncated（保持管道排空，避免死锁）。
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private var _truncated = false

    init(limit: Int) {
        self.limit = max(limit, 0)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if data.count >= limit {
            _truncated = true
            return
        }
        if data.count + chunk.count > limit {
            data.append(chunk.prefix(limit - data.count))
            _truncated = true
        } else {
            data.append(chunk)
        }
    }

    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return _truncated }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 单次运行中的进程封装。Process 非 Sendable，所有访问经内部串行队列，
/// 跨并发域只传递本类型（@unchecked Sendable 由串行化保证）。
private final class RunningProcess: @unchecked Sendable {

    enum TerminateReason { case timeout, cancelled }

    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let outBox: OutputBox
    private let errBox: OutputBox
    private let flags = TerminationFlags()
    private let queue = DispatchQueue(label: "com.cclean.processrunner")
    private var finished = false

    init(spec: ProcessSpec) {
        outBox = OutputBox(limit: spec.outputLimit)
        errBox = OutputBox(limit: spec.outputLimit)
        process.executableURL = URL(fileURLWithPath: spec.executablePath)
        process.arguments = spec.arguments
        if let env = spec.environment {
            process.environment = env
        }
        process.standardOutput = outPipe
        process.standardError = errPipe
    }

    func start() throws {
        do {
            try process.run()
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            throw ProcessRunnerError.executableNotFound(path: process.executableURL?.path ?? "?")
        } catch {
            throw ProcessRunnerError.launchFailed(
                path: process.executableURL?.path ?? "?",
                underlying: String(describing: error)
            )
        }
        outPipe.fileHandleForReading.readabilityHandler = { [outBox] handle in
            outBox.append(handle.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [errBox] handle in
            errBox.append(handle.availableData)
        }
    }

    /// 优雅终止：SIGTERM → 500ms → SIGKILL。
    /// 注意：信号发送不得经内部队列（队列可能正被 waitUntilExit 阻塞，导致终止任务饿死）。
    /// Process.terminate()/isRunning 的读取在 Apple 平台为线程安全操作。
    func terminate(reason: TerminateReason) {
        flags.mark(reason == .timeout ? .timeout : .cancelled)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// 等待退出并完成收尾（handler 摘除 + 残余数据读取）。幂等。
    func waitAndFinish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if finished {
                    cont.resume()
                    return
                }
                finished = true
                process.waitUntilExit()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outBox.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume()
            }
        }
    }

    var exitCode: Int32 {
        queue.sync { process.terminationStatus }
    }

    /// 取消竞态窗口检测：返回并清除 onCancel 标记（避免重复等待）。
    func consumeCancelledFlag() -> Bool {
        let was = flags.cancelled
        return was
    }

    func collectResult() -> (stdout: String, stderr: String, truncated: Bool, timedOut: Bool, terminated: Bool) {
        (
            outBox.text,
            errBox.text,
            outBox.truncated || errBox.truncated,
            flags.timedOut,
            flags.timedOut || flags.cancelled
        )
    }
}