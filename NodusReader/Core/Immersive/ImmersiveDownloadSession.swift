// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if os(iOS)
import UIKit
#endif

/// Downloads Immersive Audio files in a background `URLSession`, so a pack
/// keeps downloading when the reader leaves the app (iOS suspends ordinary
/// sessions). Each task carries the file it is for, so a download that
/// finishes while the app is suspended or relaunched is still verified
/// (size and SHA-256) and moved into place; nothing unverified is kept.
final class ImmersiveDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = ImmersiveDownloadSession()
    static let identifier = "ai.nodus.reader.immersive-downloads"

    /// What a task downloads: written into `taskDescription`.
    struct Target: Codable, Sendable {
        var destination: String
        var bytes: Int64
        var sha256: String
        var title: String
    }

    private let lock = NSLock()
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var progress: [Int: @Sendable (Double) -> Void] = [:]
    private var finished: [Int: Result<Void, Error>] = [:]
    /// iOS's completion for events delivered while the app was in the background.
    var backgroundCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Re-attaches to the background session at launch so downloads that
    /// finished while the app was not running are delivered.
    func reconnect() {
        _ = session
    }

    /// Downloads `url` to `target.destination`, verifying it. Cancelling the
    /// calling task cancels the download.
    func download(_ url: URL, target: Target, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let task = session.downloadTask(with: request)
        task.taskDescription = (try? String(data: JSONEncoder().encode(target), encoding: .utf8)) ?? ""
        let id = task.taskIdentifier
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                waiters[id] = continuation
                progress[id] = onProgress
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let report = progress[downloadTask.taskIdentifier]
        lock.unlock()
        report?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns: verify and move now.
        let result: Result<Void, Error>
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            result = .failure(ImmersiveAudioLibrary.LibraryError.http(http.statusCode))
        } else if let description = downloadTask.taskDescription,
                  let target = try? JSONDecoder().decode(Target.self, from: Data(description.utf8)) {
            result = Self.install(location, target: target)
        } else {
            result = .failure(ImmersiveAudioLibrary.LibraryError.unavailable)
        }
        lock.lock()
        finished[downloadTask.taskIdentifier] = result
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: task.taskIdentifier)
        progress.removeValue(forKey: task.taskIdentifier)
        let outcome = finished.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            waiter?.resume(throwing: cancelled ? CancellationError() : error)
        } else {
            waiter?.resume(with: outcome ?? .failure(ImmersiveAudioLibrary.LibraryError.unavailable))
        }
        if outcome != nil {
            NotificationCenter.default.post(name: .immersiveDownloadFinished, object: nil)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [self] in
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }

    /// Size and SHA-256 must match the manifest; otherwise the file is dropped.
    private static func install(_ location: URL, target: Target) -> Result<Void, Error> {
        let destination = URL(fileURLWithPath: target.destination)
        do {
            guard FileStore.fileSize(at: location) == target.bytes,
                  try ContentHash.sha256(of: location) == target.sha256 else {
                return .failure(ImmersiveAudioLibrary.LibraryError.integrity(target.title))
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

extension Notification.Name {
    /// A background download of a sound file finished (installed or failed).
    static let immersiveDownloadFinished = Notification.Name("ai.nodus.reader.immersiveDownloadFinished")
}

#if os(iOS)
/// Receives iOS's wake-up for background download events.
final class NodusAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == ImmersiveDownloadSession.identifier else {
            completionHandler()
            return
        }
        ImmersiveDownloadSession.shared.backgroundCompletion = completionHandler
        ImmersiveDownloadSession.shared.reconnect()
    }
}
#endif
