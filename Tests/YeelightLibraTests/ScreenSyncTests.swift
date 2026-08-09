import XCTest
@testable import YeelightLibraCore

final class ScreenSyncTests: XCTestCase {
    // MARK: - edgePixels

    func testEdgePixelsCount() {
        var pixels: [RGBPixel] = []
        for i in 0..<12 { pixels.append(RGBPixel(r: i, g: 0, b: 0)) }
        let edges = ScreenColorSampler.edgePixels(of: pixels, gridW: 4, gridH: 3)
        XCTAssertEqual(edges.count, 2 * (4 + 3) - 4)
    }

    // MARK: - averageRGB

    func testAverageRGBOverAllPixels() {
        let pixels = [RGBPixel(r: 0, g: 0, b: 0), RGBPixel(r: 255, g: 255, b: 255)]
        let avg = ScreenColorSampler.averageRGB(of: pixels, useEdges: false, gridW: 2, gridH: 1)
        XCTAssertEqual(avg, RGB(127, 127, 127)) // (0+255)/2 = 127.5, integer division → 127
    }

    func testAverageRGBEmptyReturnsNil() {
        XCTAssertNil(ScreenColorSampler.averageRGB(of: [], useEdges: false, gridW: 2, gridH: 1))
    }

    /// The edge ring must ignore the interior pixel (index 4 in a 3×3 grid).
    func testAverageRGBEdgeRingExcludesInterior() {
        var pixels: [RGBPixel] = []
        for i in 0..<9 {
            pixels.append(i == 4 ? RGBPixel(r: 255, g: 255, b: 255) : RGBPixel(r: 0, g: 0, b: 0))
        }
        let edges = ScreenColorSampler.averageRGB(of: pixels, useEdges: true, gridW: 3, gridH: 3)
        XCTAssertEqual(edges, RGB(0, 0, 0))
        let all = ScreenColorSampler.averageRGB(of: pixels, useEdges: false, gridW: 3, gridH: 3)
        XCTAssertEqual(all, RGB(28, 28, 28)) // 255/9 = 28.33 → 28
    }

    // MARK: - dominantRGB

    func testDominantRGBPicksLargestBucket() {
        let pixels = Array(repeating: RGBPixel(r: 200, g: 50, b: 50), count: 5)
            + Array(repeating: RGBPixel(r: 30, g: 200, b: 60), count: 2)
        XCTAssertEqual(ScreenColorSampler.dominantRGB(of: pixels), RGB(200, 50, 50))
    }

    func testDominantRGBEmptyReturnsNil() {
        XCTAssertNil(ScreenColorSampler.dominantRGB(of: []))
    }

    // MARK: - resolveRGB

    func testResolvePrefersDominantWhenAverageWashedOut() {
        let avg = RGB(120, 120, 124) // low saturation
        let dom = RGB(200, 60, 60)   // saturated
        XCTAssertEqual(ScreenColorSampler.resolveRGB(average: avg, dominant: dom), dom)
    }

    func testResolveKeepsAverageWhenSaturated() {
        let avg = RGB(180, 60, 40)
        let dom = RGB(200, 200, 200)
        XCTAssertEqual(ScreenColorSampler.resolveRGB(average: avg, dominant: dom), avg)
    }

    func testResolveFallsBackToEitherWhenOneMissing() {
        let avg = RGB(10, 20, 30)
        XCTAssertEqual(ScreenColorSampler.resolveRGB(average: avg, dominant: nil), avg)
        let dom = RGB(1, 2, 3)
        XCTAssertEqual(ScreenColorSampler.resolveRGB(average: nil, dominant: dom), dom)
        XCTAssertNil(ScreenColorSampler.resolveRGB(average: nil, dominant: nil))
    }

    // MARK: - tuned

    func testTunedClampsOutOfRange() {
        let out = ScreenColorSampler.tuned(RGB(300, -10, 128))
        XCTAssertEqual(out.r, 255)
        XCTAssertEqual(out.g, 0)
        XCTAssertTrue((0...255).contains(out.b))
    }

    func testTunedBoostsSaturation() {
        let rgb = RGB(160, 96, 96)
        let out = ScreenColorSampler.tuned(rgb)
        XCTAssertGreaterThan(out.saturation, rgb.saturation)
    }

    /// Near-black input must be lifted off pure black while keeping its hue.
    func testTunedLuminanceFloorPreservesHue() {
        let out = ScreenColorSampler.tuned(RGB(3, 2, 1))
        XCTAssertGreaterThan(out.r, 0)
        XCTAssertGreaterThan(out.r, out.g)
        XCTAssertGreaterThan(out.g, out.b)
    }

    // MARK: - shouldSend hysteresis

    func testShouldSendSendsWhenNoCurrentColor() {
        XCTAssertTrue(ScreenColorSampler.shouldSend(current: nil, next: RGB(100, 100, 100)))
    }

    func testShouldSendSkipsSmallDeltas() {
        XCTAssertFalse(ScreenColorSampler.shouldSend(
            current: RGB(100, 100, 100), next: RGB(104, 100, 100)))
    }

    func testShouldSendSendsOnLargeDelta() {
        XCTAssertTrue(ScreenColorSampler.shouldSend(
            current: RGB(100, 100, 100), next: RGB(110, 100, 100)))
    }

    // MARK: - delivery coalescing

    func testTCPThrottleKeepsLatestPendingColor() {
        var delivery = ScreenSyncDelivery(tcpInterval: 0.5)
        let t0 = Date(timeIntervalSince1970: 100)
        let first = RGB(100, 20, 20)
        let latest = RGB(20, 100, 20)

        XCTAssertEqual(delivery.offer(first, now: t0, chromaAvailable: false), .tcp(first))
        XCTAssertNil(delivery.offer(latest, now: t0.addingTimeInterval(0.1), chromaAvailable: false))
        XCTAssertTrue(delivery.hasPendingTCP)

        XCTAssertEqual(
            delivery.finishTCP(succeeded: true, now: t0.addingTimeInterval(0.6), chromaAvailable: false),
            .tcp(latest))
    }

    func testCompletionBeforeThrottleWindowSchedulesPendingFlush() {
        var delivery = ScreenSyncDelivery(tcpInterval: 0.5)
        let t0 = Date(timeIntervalSince1970: 100)
        let first = RGB(100, 20, 20)
        let latest = RGB(20, 100, 20)

        XCTAssertEqual(delivery.offer(first, now: t0, chromaAvailable: false), .tcp(first))
        XCTAssertNil(delivery.offer(latest, now: t0.addingTimeInterval(0.1), chromaAvailable: false))
        XCTAssertNil(delivery.finishTCP(succeeded: true, now: t0.addingTimeInterval(0.2), chromaAvailable: false))
        XCTAssertEqual(
            delivery.flush(now: t0.addingTimeInterval(0.5), chromaAvailable: false),
            .tcp(latest))
    }

    func testStableColorIsNotRepeatedAfterTCPStarts() {
        var delivery = ScreenSyncDelivery(tcpInterval: 0)
        let color = RGB(100, 20, 20)
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(delivery.offer(color, now: now, chromaAvailable: false), .tcp(color))
        XCTAssertNil(delivery.offer(color, now: now.addingTimeInterval(1), chromaAvailable: false))
    }

    func testFailedTCPSendIsRequeued() {
        var delivery = ScreenSyncDelivery(tcpInterval: 0)
        let color = RGB(100, 20, 20)
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(delivery.offer(color, now: now, chromaAvailable: false), .tcp(color))
        XCTAssertEqual(
            delivery.finishTCP(succeeded: false, now: now.addingTimeInterval(1), chromaAvailable: false),
            .tcp(color))
    }

    func testChromaTakesPriorityOverTCPAndMarksColorDelivered() {
        var delivery = ScreenSyncDelivery(tcpInterval: 0.5)
        let color = RGB(10, 20, 30)
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(delivery.offer(color, now: now, chromaAvailable: true), .chroma(color))
        XCTAssertNil(delivery.offer(color, now: now.addingTimeInterval(1), chromaAvailable: true))
        XCTAssertEqual(delivery.lastDelivered, color)
    }
}
