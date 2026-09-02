import Foundation
import os

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: @unchecked Sendable {
        var statusCode: Int = 200
        var data: Data = Data()
        var error: Error?
        var onRequest: (@Sendable (URLRequest) -> Void)?
    }

    private static let stubLock = OSAllocatedUnfairLock<Stub?>(
        initialState: nil,
    )

    static var stub: Stub? {
        get { stubLock.withLock { $0 } }
        set { stubLock.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest,
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let stub = Self.stub else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL),
            )
            return
        }
        stub.onRequest?(request)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"],
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed,
        )
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
