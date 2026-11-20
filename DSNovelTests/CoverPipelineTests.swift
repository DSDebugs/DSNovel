import XCTest
import UIKit
@testable import DSNovel

private actor CountingFakeCoverFetcher: CoverImageDataFetching {
    private(set) var requestCount = 0
    private let imageData: Data

    init() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let img = renderer.image { ctx in
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        self.imageData = img.pngData() ?? Data(repeating: 1, count: 2048)
    }

    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        try? await Task.sleep(for: .milliseconds(40))
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )!
        return (imageData, response)
    }
}

final class CoverPipelineTests: XCTestCase {

    func testConcurrentRequestsForSameURLAreMerged() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("CoverMerge_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        let fetcher = CountingFakeCoverFetcher()
        let pipeline = CoverImagePipeline(diskDirectory: tempDir, maxDiskBytes: 10 * 1024 * 1024, fetcher: fetcher)

        await withTaskGroup(of: UIImage?.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await pipeline.loadImage(
                        url: "https://example.invalid/same_cover.png",
                        targetPointSize: CGSize(width: 80, height: 80)
                    )
                }
            }
            for await img in group {
                XCTAssertNotNil(img)
            }
        }

        let count = await fetcher.requestCount
        XCTAssertEqual(count, 1, "同一 URL 并发 10 次应仅发起 1 次底层网络请求")
    }

    func testDiskCacheEvictsToUnderMaxLimit() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("CoverEvict_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        let maxBytes = 4_000
        let fetcher = CountingFakeCoverFetcher()
        let pipeline = CoverImagePipeline(
            diskDirectory: tempDir,
            maxDiskBytes: maxBytes,
            evictionThrottleInterval: 0,
            fetcher: fetcher
        )

        for i in 0..<15 {
            _ = await pipeline.loadImage(
                url: "https://example.invalid/cover_\(i).png",
                targetPointSize: CGSize(width: 80, height: 80)
            )
        }
        await pipeline.evictDiskCacheIfNeeded(force: true)
        let usage = await pipeline.diskUsageBytes()
        XCTAssertLessThanOrEqual(usage, Int64(maxBytes))
    }
}
