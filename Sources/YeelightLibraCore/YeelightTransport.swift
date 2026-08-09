import Foundation

/// Seam between typed device operations and a concrete Yeelight wire
/// transport. YeelightClient is the production Network.framework adapter;
/// tests and future transports can provide the same request interface.
@MainActor
protocol YeelightTransport: AnyObject {
    func send(_ request: YeelightRequest) async throws -> [Any]
}

extension YeelightClient: YeelightTransport {
    func send(_ request: YeelightRequest) async throws -> [Any] {
        try await command(request)
    }
}
