import ClementineCore
import XCTest

final class OutputNamerTests: XCTestCase {
    func testNames() {
        XCTAssertEqual(OutputNamer.name(base: "photo", extension: "jpg"), "photo.jpg")
        XCTAssertEqual(OutputNamer.name(base: "photo", number: 2, extension: "jpg"), "photo 2.jpg")
        XCTAssertEqual(OutputNamer.name(base: "video", suffix: "trimmed", extension: "mp4"), "video (trimmed).mp4")
        XCTAssertEqual(OutputNamer.name(base: "video", suffix: "1.5x", number: 3, extension: "mp4"), "video (1.5x) 3.mp4")
        XCTAssertEqual(OutputNamer.name(base: "report", extension: ""), "report")
        XCTAssertEqual(OutputNamer.pageName(7, of: 12), "Page 007")
        XCTAssertEqual(OutputNamer.pageName(7, of: 1200), "Page 0007")
    }

    func testUniqueSkipsExisting() {
        let dir = URL(fileURLWithPath: "/x")
        let taken: Set<String> = ["/x/photo.jpg", "/x/photo 2.jpg"]
        let url = OutputNamer.uniqueURL(in: dir, base: "photo", extension: "jpg") { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "photo 3.jpg")
    }
}

final class AtomicOutputTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCommitNeverOverwrites() throws {
        let existing = dir.appendingPathComponent("photo.jpg")
        try Data("old".utf8).write(to: existing)
        let out = try AtomicOutput(directory: dir, base: "photo", extension: "jpg")
        XCTAssertTrue(out.tempURL.lastPathComponent.hasPrefix("."))
        XCTAssertEqual(out.tempURL.pathExtension, "jpg")
        try Data("new".utf8).write(to: out.tempURL)
        let final = try out.commit()
        XCTAssertEqual(final.lastPathComponent, "photo 2.jpg")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.tempURL.path))
    }

    func testDiscardRemovesTemp() throws {
        let out = try AtomicOutput(directory: dir, base: "x", suffix: "compressed", extension: "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.tempURL.path))
        out.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.tempURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testFolderOutput() throws {
        let out = try AtomicOutput(directory: dir, base: "report", extension: "", isDirectory: true)
        try Data().write(to: out.tempURL.appendingPathComponent("Page 001.jpg"))
        let final = try out.commit()
        XCTAssertEqual(final.lastPathComponent, "report")
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.appendingPathComponent("Page 001.jpg").path))
    }

    func testPlannerFallsBackToDownloads() throws {
        let downloads = dir.appendingPathComponent("Downloads")
        let planner = OutputPlanner(location: .besideOriginal, downloads: downloads)
        let source = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/photo.heic")
        let (out, fellBack) = try planner.makeOutput(for: source, extension: "jpg")
        XCTAssertTrue(fellBack)
        XCTAssertEqual(out.directory.standardizedFileURL, downloads.standardizedFileURL)
        out.discard()
    }
}

final class JobQueueTests: XCTestCase {
    struct FakeExecutor: JobExecuting {
        func execute(_ job: Job) async throws -> JobResult {
            if job.request.inputs.first?.url.lastPathComponent == "fail.png" {
                throw JobFailure("boom")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            return JobResult(outputs: [job.request.inputs[0].url])
        }
    }

    func testRunsAndReports() async throws {
        let done = expectation(description: "finished")
        done.expectedFulfillmentCount = 2
        let queue = JobQueue(executor: FakeExecutor()) { job in
            if job.state.isFinished { done.fulfill() }
        }
        let ok = Job(JobRequest(inputs: [InputItem(url: URL(fileURLWithPath: "/tmp/a.png"), isDirectory: false)],
                                operation: .convert(.jpg)))
        let bad = Job(JobRequest(inputs: [InputItem(url: URL(fileURLWithPath: "/tmp/fail.png"), isDirectory: false)],
                                 operation: .convert(.jpg)))
        await queue.submit(ok)
        await queue.submit(bad)
        await fulfillment(of: [done], timeout: 5)
        guard case .succeeded = ok.state else { return XCTFail("expected success, got \(ok.state)") }
        guard case .failed(let f) = bad.state else { return XCTFail("expected failure") }
        XCTAssertEqual(f.message, "boom")
        XCTAssertEqual(ok.progress.fractionCompleted, 1, accuracy: 0.001)
    }

    func testCancelQueued() async throws {
        let queue = JobQueue(executor: FakeExecutor(), limits: [.image: 1]) { _ in }
        let jobs = (0..<3).map { i in
            Job(JobRequest(inputs: [InputItem(url: URL(fileURLWithPath: "/tmp/\(i).png"), isDirectory: false)],
                           operation: .convert(.jpg)))
        }
        for j in jobs { await queue.submit(j) }
        XCTAssertTrue(jobs[2].cancel())
        guard case .cancelled = jobs[2].state else { return XCTFail("expected cancelled") }
    }

    func testLanes() {
        func req(_ name: String, _ op: JobOperation) -> JobRequest {
            JobRequest(inputs: [InputItem(url: URL(fileURLWithPath: "/tmp/\(name)"), isDirectory: false)], operation: op)
        }
        XCTAssertEqual(JobQueue.lane(for: req("a.png", .convert(.jpg))), .image)
        XCTAssertEqual(JobQueue.lane(for: req("a.mov", .convert(.mp4))), .media)
        XCTAssertEqual(JobQueue.lane(for: req("a.pdf", .convert(.txt))), .document)
        XCTAssertEqual(JobQueue.lane(for: req("a.zip", .convert(.extract))), .archive)
        XCTAssertEqual(JobQueue.lane(for: req("a.mp3", .tool(.trim))), .media)
    }
}
