import XCTest
@testable import YeelightLibraCore

final class ChromaSessionTests: XCTestCase {
    private var savedDeviceIP: String?

    override func setUpWithError() throws {
        // host.didSet persists to UserDefaults.standard; save/restore so tests
        // don't pollute the real defaults used by the app.
        savedDeviceIP = UserDefaults.standard.string(forKey: "deviceIP")
    }

    override func tearDownWithError() throws {
        if let savedDeviceIP {
            UserDefaults.standard.set(savedDeviceIP, forKey: "deviceIP")
        } else {
            UserDefaults.standard.removeObject(forKey: "deviceIP")
        }
    }

    // MARK: - ChromaSession lifecycle

    func testInitialStateIsStoppedAndDisconnected() {
        let session = ChromaSession(host: "192.168.1.10")
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(session.isConnected)
        XCTAssertTrue(session.token.isEmpty)
        XCTAssertEqual(session.host, "192.168.1.10")
    }

    func testStartMarksSessionRunningAndStopStopsIt() {
        let session = ChromaSession(host: "192.168.1.10")
        session.start()
        XCTAssertTrue(session.isRunning)
        session.stop()
        XCTAssertFalse(session.isRunning)
    }

    func testStopClearsTokenAndDisconnects() {
        let session = ChromaSession(host: "192.168.1.10")
        session.token = "test-token"
        session.isConnected = true
        session.stop()
        // stop() clears token/isRunning synchronously but flips isConnected on
        // the main queue; wait for the async update.
        waitUntil { !session.isConnected }
        XCTAssertTrue(session.token.isEmpty)
        XCTAssertFalse(session.isConnected)
        XCTAssertFalse(session.isRunning)
    }

    // MARK: - YeelightClient host switching

    func testHostChangeRecreatesChromaSession() {
        let client = YeelightClient(host: "192.168.1.10")
        let old = client.chroma
        client.host = "192.168.1.11"
        XCTAssertNotIdentical(client.chroma, old)
        XCTAssertEqual(client.chroma.host, "192.168.1.11")
    }

    func testHostChangeKeepsRunningChromaRunning() {
        let client = YeelightClient(host: "192.168.1.10")
        client.chroma.start()
        XCTAssertTrue(client.chroma.isRunning)

        client.host = "192.168.1.11"

        XCTAssertTrue(client.chroma.isRunning)
        XCTAssertEqual(client.chroma.host, "192.168.1.11")
        client.chroma.stop()
    }

    func testHostChangeDoesNotStartStoppedChroma() {
        let client = YeelightClient(host: "192.168.1.10")
        XCTAssertFalse(client.chroma.isRunning)

        client.host = "192.168.1.11"

        XCTAssertFalse(client.chroma.isRunning)
        XCTAssertEqual(client.chroma.host, "192.168.1.11")
    }

    func testSameHostDoesNotRecreateChromaSession() {
        let client = YeelightClient(host: "192.168.1.10")
        let old = client.chroma
        client.host = "192.168.1.10"
        XCTAssertIdentical(client.chroma, old)
    }

    func testHostChangePersistsToUserDefaults() {
        let client = YeelightClient(host: "192.168.1.10")
        client.host = "192.168.1.12"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "deviceIP"), "192.168.1.12")
    }

    // MARK: - chromaConnected mirror

    func testChromaConnectedMirrorsSessionState() {
        let client = YeelightClient(host: "192.168.1.10")
        XCTAssertFalse(client.chromaConnected)

        client.chroma.isConnected = true
        waitUntil { client.chromaConnected }
        XCTAssertTrue(client.chromaConnected)

        client.chroma.isConnected = false
        waitUntil { !client.chromaConnected }
        XCTAssertFalse(client.chromaConnected)
    }

    func testChromaConnectedMirrorSurvivesSessionRecreation() {
        let client = YeelightClient(host: "192.168.1.10")
        client.host = "192.168.1.11"

        // didSet rebinds the new session; a later connection must still propagate.
        client.chroma.isConnected = true
        waitUntil { client.chromaConnected }
        XCTAssertTrue(client.chromaConnected)
    }

    /// Polls `condition` on the run loop until it becomes true (the Combine
    /// mirror delivers on the main queue). Fails the test on timeout.
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) {
        let predicate = NSPredicate { _, _ in condition() }
        let exp = expectation(for: predicate, evaluatedWith: nil)
        wait(for: [exp], timeout: timeout)
    }
}
