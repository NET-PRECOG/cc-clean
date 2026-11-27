import Testing
import Foundation
@testable import CcCleanCore

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    let runner = ProcessRunner()

    // MARK: - 基础执行

    @Test("成功执行：exit 0 + stdout 正确")
    func successRun() async throws {
        let result = try await runner.run(.init(
            executablePath: "/bin/echo",
            arguments: ["hello"]
        ))
        #expect(result.succeeded)
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .newlines) == "hello")
        #expect(!result.truncated)
        #expect(!result.timedOut)
        #expect(!result.cancelled)
    }

    @Test("非零退出码：不抛错，exitCode 正确")
    func nonZeroExitCode() async throws {
        let result = try await runner.run(.init(
            executablePath: "/bin/sh",
            arguments: ["-c", "exit 3"]
        ))
        #expect(!result.succeeded)
        #expect(result.exitCode == 3)
    }

    @Test("stderr 捕获")
    func stderrCapture() async throws {
        let result = try await runner.run(.init(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo err-line >&2"]
        ))
        #expect(result.stderr.trimmingCharacters(in: .newlines) == "err-line")
    }

    // MARK: - 超时

    @Test("超时：SIGTERM 终止并标记 timedOut")
    func timeout() async throws {
        let start = Date()
        let result = try await runner.run(.init(
            executablePath: "/bin/sleep",
            arguments: ["30"],
            timeout: .milliseconds(300)
        ))
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.timedOut)
        #expect(result.terminatedByRunner)
        #expect(elapsed < 5)  // 未真等 30s
        #expect(!result.succeeded)
    }

    // MARK: - 取消

    @Test("取消：外部 cancel 后返回 cancelled 标记")
    func cancellation() async throws {
        let task = Task {
            try await runner.run(.init(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                timeout: .seconds(60)
            ))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = try await task.value
        #expect(result.cancelled)
        #expect(result.terminatedByRunner)
    }

    // MARK: - 输出截断

    @Test("输出截断：超限标记 truncated 且管道不阻塞")
    func outputTruncation() async throws {
        // seq 1 100000 约 588KB，远超 10KB 上限
        let result = try await runner.run(.init(
            executablePath: "/usr/bin/seq",
            arguments: ["1", "100000"],
            outputLimit: 10_000,
            timeout: .seconds(20)
        ))
        #expect(result.succeeded)
        #expect(result.truncated)
        #expect(result.stdout.utf8.count <= 10_000)
        #expect(result.stdout.hasPrefix("1\n"))
    }

    // MARK: - 环境注入

    @Test("环境全量替换：自定义变量可见，PATH 可控")
    func environmentInjection() async throws {
        let result = try await runner.run(.init(
            executablePath: "/usr/bin/env",
            environment: ["MACPILOT_TEST_VAR": " injected ", "PATH": "/usr/bin:/bin"]
        ))
        #expect(result.stdout.contains("MACPILOT_TEST_VAR= injected "))
        #expect(!result.stdout.contains("HOME="))  // 全量替换后继承变量不可见
    }

    @Test("环境 nil：继承当前进程环境")
    func environmentInherited() async throws {
        setenv("MACPILOT_INHERIT_TEST", "yes", 1)
        defer { unsetenv("MACPILOT_INHERIT_TEST") }
        let result = try await runner.run(.init(executablePath: "/usr/bin/env"))
        #expect(result.stdout.contains("MACPILOT_INHERIT_TEST=yes"))
    }

    // MARK: - 特殊字符

    @Test("参数含中文 / emoji / 空格：无 shell 拼接，原样传递")
    func unicodeArguments() async throws {
        let payload = "中文 参数🎉 with space"
        let result = try await runner.run(.init(
            executablePath: "/bin/echo",
            arguments: [payload]
        ))
        #expect(result.stdout.trimmingCharacters(in: .newlines) == payload)
    }

    // MARK: - 启动失败

    @Test("可执行文件不存在：抛 executableNotFound")
    func executableNotFound() async {
        await #expect(throws: ProcessRunnerError.executableNotFound(path: "/nonexistent/binary")) {
            _ = try await runner.run(.init(executablePath: "/nonexistent/binary"))
        }
    }

    // MARK: - 并发

    @Test("并发执行互不干扰")
    func concurrentRuns() async throws {
        let results = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            for i in 1...4 {
                group.addTask {
                    try await self.runner.run(.init(
                        executablePath: "/bin/echo",
                        arguments: ["task-\(i)"]
                    ))
                }
            }
            var collected: [ProcessResult] = []
            for try await r in group { collected.append(r) }
            return collected
        }
        let outputs = results.map { $0.stdout.trimmingCharacters(in: .newlines) }.sorted()
        #expect(outputs == ["task-1", "task-2", "task-3", "task-4"])
    }

    // MARK: - 大输出 + 长 stderr 同时排空（死锁回归）

    @Test("stdout 与 stderr 同时大量输出：无死锁")
    func bothStreamsHeavy() async throws {
        let result = try await runner.run(.init(
            executablePath: "/bin/sh",
            arguments: ["-c", "seq 1 50000 & seq 1 50000 >&2; wait"],
            outputLimit: 100_000,
            timeout: .seconds(30)
        ))
        #expect(result.succeeded)
        #expect(result.truncated)  // 双路都超过 100KB 限制
        #expect(!result.stdout.isEmpty)
        #expect(!result.stderr.isEmpty)
    }
}