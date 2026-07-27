import Foundation
import VelaDomain

public struct AttachmentUploadRequest: Hashable, Codable, Sendable {
    public var attachmentID: AttachmentID
    public var sourceURL: URL
    public var mimeType: String
    public var fileName: String?
    public var byteCount: Int64

    public init(
        attachmentID: AttachmentID = .random(),
        sourceURL: URL,
        mimeType: String,
        fileName: String?,
        byteCount: Int64
    ) {
        self.attachmentID = attachmentID
        self.sourceURL = sourceURL
        self.mimeType = mimeType
        self.fileName = fileName
        self.byteCount = byteCount
    }
}

public struct UploadedAttachmentPointer: Hashable, Codable, Sendable {
    public var attachmentID: AttachmentID
    public var opaqueServicePointer: Data
    public var encryptedByteCount: Int64

    public init(attachmentID: AttachmentID, opaqueServicePointer: Data, encryptedByteCount: Int64) {
        self.attachmentID = attachmentID
        self.opaqueServicePointer = opaqueServicePointer
        self.encryptedByteCount = encryptedByteCount
    }
}

public protocol AttachmentTransferService: Sendable {
    func upload(_ request: AttachmentUploadRequest) async throws -> UploadedAttachmentPointer
    func download(_ reference: AttachmentReference, destination: URL) async throws
    func cancel(attachmentID: AttachmentID) async
}

public enum AttachmentDownloadQueueError: Error, Sendable, LocalizedError {
    case full

    public var errorDescription: String? {
        switch self {
        case .full: "The attachment download queue is full."
        }
    }
}

/// Bounds attachment I/O without blocking message receive work on one large
/// batch. Jobs wait FIFO; cancellation removes queued or active work promptly.
public actor AttachmentDownloadQueue {
    public typealias Operation = @Sendable () async throws -> Void

    private struct Job {
        let id: UUID
        let attachmentID: AttachmentID
        let operation: Operation
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct ActiveJob {
        let attachmentID: AttachmentID
        let continuation: CheckedContinuation<Void, any Error>
        let task: Task<Void, Never>
    }

    private let maximumConcurrent: Int
    private let maximumPending: Int
    private var pending: [Job] = []
    private var active: [UUID: ActiveJob] = [:]

    public init(maximumConcurrent: Int = 3, maximumPending: Int = 64) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.maximumPending = max(1, maximumPending)
    }

    public func enqueue(
        attachmentID: AttachmentID,
        operation: @escaping Operation
    ) async throws {
        let jobID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard pending.count < maximumPending else {
                    continuation.resume(throwing: AttachmentDownloadQueueError.full)
                    return
                }
                pending.append(
                    Job(
                        id: jobID,
                        attachmentID: attachmentID,
                        operation: operation,
                        continuation: continuation
                    )
                )
                startAvailableJobs()
            }
        } onCancel: {
            Task { await self.cancel(jobID: jobID) }
        }
    }

    public func cancel(attachmentID: AttachmentID) {
        let queued = pending.filter { $0.attachmentID == attachmentID }
        pending.removeAll { $0.attachmentID == attachmentID }
        for job in queued {
            job.continuation.resume(throwing: CancellationError())
        }

        let activeIDs = active.compactMap { id, job in
            job.attachmentID == attachmentID ? id : nil
        }
        for id in activeIDs {
            cancel(jobID: id)
        }
        startAvailableJobs()
    }

    private func startAvailableJobs() {
        while active.count < maximumConcurrent, !pending.isEmpty {
            let job = pending.removeFirst()
            let task = Task { [weak self] in
                let result: Result<Void, any Error>
                do {
                    try await job.operation()
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                await self?.finish(jobID: job.id, result: result)
            }
            active[job.id] = ActiveJob(
                attachmentID: job.attachmentID,
                continuation: job.continuation,
                task: task
            )
        }
    }

    private func finish(jobID: UUID, result: Result<Void, any Error>) {
        guard let job = active.removeValue(forKey: jobID) else { return }
        job.continuation.resume(with: result)
        startAvailableJobs()
    }

    private func cancel(jobID: UUID) {
        if let index = pending.firstIndex(where: { $0.id == jobID }) {
            let job = pending.remove(at: index)
            job.continuation.resume(throwing: CancellationError())
            return
        }
        guard let job = active.removeValue(forKey: jobID) else { return }
        job.task.cancel()
        job.continuation.resume(throwing: CancellationError())
        startAvailableJobs()
    }
}

/// Adds bounded FIFO downloads to any attachment backend. Uploads keep their
/// backend behavior; only inbound file transfer is scheduled.
public actor QueuedAttachmentTransferService: AttachmentTransferService {
    private let base: any AttachmentTransferService
    private let queue: AttachmentDownloadQueue

    public init(
        base: any AttachmentTransferService,
        maximumConcurrentDownloads: Int = 3,
        maximumPendingDownloads: Int = 64
    ) {
        self.base = base
        self.queue = AttachmentDownloadQueue(
            maximumConcurrent: maximumConcurrentDownloads,
            maximumPending: maximumPendingDownloads
        )
    }

    public func upload(_ request: AttachmentUploadRequest) async throws -> UploadedAttachmentPointer {
        try await base.upload(request)
    }

    public func download(_ reference: AttachmentReference, destination: URL) async throws {
        try await queue.enqueue(attachmentID: reference.id) { [base] in
            try await base.download(reference, destination: destination)
        }
    }

    public func cancel(attachmentID: AttachmentID) async {
        await queue.cancel(attachmentID: attachmentID)
        await base.cancel(attachmentID: attachmentID)
    }
}

public struct UnavailableAttachmentTransferService: AttachmentTransferService {
    public init() {}

    public func upload(_ request: AttachmentUploadRequest) async throws -> UploadedAttachmentPointer {
        throw VelaError.productionIntegrationRequired("Signal attachment encryption and upload")
    }

    public func download(_ reference: AttachmentReference, destination: URL) async throws {
        throw VelaError.productionIntegrationRequired("Signal attachment download and integrity verification")
    }

    public func cancel(attachmentID: AttachmentID) async {}
}
