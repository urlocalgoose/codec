import Foundation
import Network

/// A usable network path is evidence of a connection, not proof that the
/// internet or this particular server works. HTTP results provide that part.
enum NetworkAvailability: Sendable, Equatable {
    case unknown
    case available
    case unavailable
}

enum ConnectionIssue: Equatable {
    case noNetwork
    case serverUnreachable
    case serverUnavailable
    case authentication
    case secureConnection
    case invalidServer

    static func classify(_ error: Error, network: NetworkAvailability) -> Self {
        if network == .unavailable { return .noNetwork }
        if let error = error as? CodecClientError {
            switch error {
            case .httpStatus(let status, _):
                if status == 401 || status == 403 { return .authentication }
                return status >= 500 ? .serverUnavailable : .invalidServer
            case .invalidBaseURL, .invalidResponse:
                return .invalidServer
            }
        }
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                return .noNetwork
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return .secureConnection
            case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
                return .invalidServer
            default: break
            }
        }
        // DNS failure and timeouts cannot establish whether the host, tunnel,
        // router, or wider internet failed. Do not label all of them "server down".
        return .serverUnreachable
    }

    var automaticallyRetries: Bool {
        switch self {
        case .authentication, .secureConnection, .invalidServer: false
        default: true
        }
    }

    var title: String {
        switch self {
        case .noNetwork: "No network connection"
        case .serverUnreachable: "Can’t reach your server"
        case .serverUnavailable: "Server temporarily unavailable"
        case .authentication: "Check your auth token"
        case .secureConnection: "Secure connection failed"
        case .invalidServer: "Check your server address"
        }
    }

    var detail: String {
        switch self {
        case .noNetwork: "Your downloads are ready to play. Codec will reconnect when a connection is available."
        case .serverUnreachable: "Codec will keep trying. Downloaded music is still available."
        case .serverUnavailable: "The server returned an error. Codec will retry while your downloads keep working."
        case .authentication: "The server rejected this token. Update it in Settings to reconnect."
        case .secureConnection: "Check the server’s HTTPS address and certificate. Your downloads are still available."
        case .invalidServer: "Enter the address of your Codec server and try again."
        }
    }
}

@MainActor
final class ConnectivityMonitor {
    private var monitor: NWPathMonitor?

    func start(_ onChange: @escaping @MainActor (NetworkAvailability) -> Void) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            let state: NetworkAvailability
            switch path.status {
            case .satisfied: state = .available
            case .unsatisfied: state = .unavailable
            default: state = .unknown
            }
            Task { @MainActor in onChange(state) }
        }
        monitor.start(queue: DispatchQueue(label: "codec.connectivity", qos: .utility))
    }

    deinit { monitor?.cancel() }
}
