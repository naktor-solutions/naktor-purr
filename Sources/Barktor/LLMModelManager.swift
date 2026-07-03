import CryptoKit
import Foundation
import os.log

// Tracks the local install state of the Gemma 3 4B GGUF weights used by
// MeetingSummarizer's llama.cpp backend.
//
// We download a single quantized GGUF (Q4_K_M, ~2.49 GB) from Hugging
// Face and park it under ~/Library/Application Support/Barktor/models/
// alongside the Parakeet / Whisper weights so the user can find and
// delete models without spelunking ~/Library, and the location survives
// `defaults delete`.
//
// The Gemma Terms of Use require a flow-down notice when exposing the
// model's functionality through a UI; the Settings panel renders that
// notice inline before triggering a download.
enum LLMModelManager {
    private static let log = Logger(subsystem: "com.naktor.barktor", category: "llm-models")

    static let defaultModelFilename = "gemma-3-4b-it-Q4_K_M.gguf"
    static let defaultModelLabel = "Gemma 3 4B Instruct (Q4_K_M)"
    static let defaultModelSizeMB = 2_490
    static let defaultModelURL = URL(
        string:
            "https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf"
    )!
    static let licenseURL = URL(string: "https://ai.google.dev/gemma/terms")!
    static let licenseName = "Gemma Terms of Use"

    // Pinned to the canonical Q4_K_M GGUF published by `unsloth` on
    // Hugging Face. Source of truth:
    //   https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/blob/main/gemma-3-4b-it-Q4_K_M.gguf
    // Verifying before the file reaches llama.cpp closes the supply-chain
    // path through a compromised HF mirror or tampered CDN edge.
    static let defaultModelSHA256 =
        "04a43a22e8d2003deda5acc262f68ec1005fa76c735a9962a8c77042a74a7d19"
    static let defaultModelExpectedSize: Int64 = 2_489_894_016

    static var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        let dir = support.appendingPathComponent("Barktor/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var localURL: URL {
        modelsDirectory.appendingPathComponent(defaultModelFilename, isDirectory: false)
    }

    static func isInstalled() -> Bool {
        let path = localURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return false
        }
        // Guard against a previous partial download that left a stub file
        // behind. Real Q4_K_M weights are 2.3 GB+; anything radically
        // smaller is treated as missing so the next download retries
        // cleanly.
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return size > 1_000_000_000  // 1 GB threshold
    }

    static func delete() throws {
        let url = localURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
            log.info("Deleted Gemma GGUF at \(url.path, privacy: .public)")
        }
    }

    // Streams the GGUF to disk via URLSession.download. We bypass the
    // higher-level `URLSession.download(from:)` async API in favour of a
    // delegate so we get incremental progress for the UI. Cancellation is
    // handled at the Task level by callers - the delegate just reports
    // bytes-written.
    @discardableResult
    static func download(progress: @escaping (Double) -> Void) async throws -> URL {
        let destination = localURL
        // Defensive: if a previous corrupted file is sitting at the final
        // path (size below the install threshold but non-zero) it would
        // shadow the new download until we explicitly remove it.
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        log.info("Downloading Gemma GGUF -> \(destination.path, privacy: .public)")
        let downloader = GGUFDownloader()
        let tempURL = try await downloader.download(
            from: defaultModelURL,
            progress: progress
        )

        // Verify BEFORE moving into place; a mismatched temp file is
        // deleted so the next retry restarts from scratch.
        do {
            try verifyDownloadedGGUF(at: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // Atomic move from URLSession's temp file to the final location.
        try FileManager.default.moveItem(at: tempURL, to: destination)
        log.info(
            "Gemma GGUF installed (\(formatSize(at: destination), privacy: .public))"
        )
        return destination
    }

    // Size check first - it's a free fast-fail before the multi-second streaming hash of a 2.5 GB file.
    private static func verifyDownloadedGGUF(at url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == defaultModelExpectedSize else {
            log.error(
                "Gemma GGUF size mismatch: got \(actualSize, privacy: .public), expected \(defaultModelExpectedSize, privacy: .public)."
            )
            throw IntegrityError.sizeMismatch(expected: defaultModelExpectedSize, actual: actualSize)
        }

        let digest = try sha256OfFile(at: url).lowercased()
        let expected = defaultModelSHA256.lowercased()
        guard digest == expected else {
            log.error(
                "Gemma GGUF SHA-256 mismatch: got \(digest, privacy: .public), expected \(expected, privacy: .public)."
            )
            throw IntegrityError.hashMismatch(expected: expected, actual: digest)
        }
        log.info("Gemma GGUF SHA-256 verified.")
    }

    // 4 MiB chunks so peak memory stays bounded against the 2.5 GB file.
    static func sha256OfFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let bufferSize = 4 * 1024 * 1024
        while true {
            let chunk = try handle.read(upToCount: bufferSize) ?? Data()
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { raw in
                hasher.update(bufferPointer: raw)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum IntegrityError: LocalizedError {
        case sizeMismatch(expected: Int64, actual: Int64)
        case hashMismatch(expected: String, actual: String)

        var errorDescription: String? {
            switch self {
            case .sizeMismatch(let expected, let actual):
                return
                    "Gemma model download was \(actual) bytes; expected \(expected). The file was rejected to protect against a corrupted or tampered download. Try again."
            case .hashMismatch:
                return
                    "Gemma model download failed integrity verification (SHA-256 mismatch). The file was rejected. Try again, and if this persists check your network for a captive portal or proxy."
            }
        }
    }

    private static func formatSize(at url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

// URLSession-based downloader with progress reporting. Keeps state out
// of LLMModelManager so the enum stays pure. The session uses a default
// configuration - the GGUF is large but URLSession streams chunks to
// disk so peak memory stays low.
private final class GGUFDownloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: ((Double) -> Void)?

    // URLSession with a delegate retains the delegate via its session,
    // forming a session → delegate → continuation cycle that only breaks
    // when the session is invalidated. Keep a strong ref so we can tear
    // it down on every completion path.
    private var session: URLSession?

    func download(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        progressHandler = progress
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withCheckedThrowingContinuation { (cc: CheckedContinuation<URL, Error>) in
            self.continuation = cc
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        session?.finishTasksAndInvalidate()
        session = nil
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let err): cont.resume(throwing: err)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler?(fraction)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move the URLSession temp file to a stable tmp location before
        // returning - URLSession deletes the original on delegate return.
        let stableTmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "barktor-gguf-\(UUID().uuidString).gguf")
        do {
            try FileManager.default.moveItem(at: location, to: stableTmp)
            finish(.success(stableTmp))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        if let error = error {
            finish(.failure(error))
        }
    }
}
