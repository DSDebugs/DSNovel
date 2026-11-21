import Foundation

struct DownloadTaskDescriptor: Codable, Equatable, Sendable {
    let itemID: String
    let bookID: String
    let chapterID: String
    let resolvedBy: String
}

enum DownloadTransportEvent: Sendable {
    case progress(itemID: String, fraction: Double)
    case finished(
        descriptor: DownloadTaskDescriptor,
        tempFileURL: URL,
        statusCode: Int,
        mimeType: String?,
        originalURL: URL? = nil,
        suggestedFilename: String? = nil,
        expectedContentLength: Int64? = nil
    )
    case failed(descriptor: DownloadTaskDescriptor, statusCode: Int?, errorDescription: String)
}

@MainActor
protocol DownloadTransport: AnyObject {
    var onEvent: ((DownloadTransportEvent) -> Void)? { get set }
    func start(request: URLRequest, descriptor: DownloadTaskDescriptor, resumeData: Data?)
    func pause(itemID: String) async -> Data?
    func cancel(itemID: String)
    func activeTaskItemIDs() async -> Set<String>
    func cancelTasksDisallowingMismatch(allowsCellular: Bool) async -> [String]
}
