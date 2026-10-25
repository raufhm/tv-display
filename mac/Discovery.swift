// Finds TV Display receivers on the local network. Each TV advertises the Bonjour service
// "_tvdisplay._tcp" with its IPv4 address and port in the TXT record, so no resolving is needed.

import Foundation
import Network

struct FoundTV: Equatable {
    let name: String
    let ip: String
    let port: UInt16
}

final class Discovery {
    static let serviceType = "_tvdisplay._tcp"
    private var browser: NWBrowser?
    private(set) var tvs: [FoundTV] = []
    var onChange: (([FoundTV]) -> Void)?

    func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        b.stateUpdateHandler = { state in
            if case .failed(let e) = state { log("discovery failed: \(e)") }
        }
        b.start(queue: .main)
        browser = b
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var found: [FoundTV] = []
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint,
                  case let .bonjour(txt) = r.metadata,
                  let ip = txt["ip"] else { continue }
            let port = txt["port"].flatMap { UInt16($0) } ?? 7777
            found.append(FoundTV(name: name, ip: ip, port: port))
        }
        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard found != tvs else { return }
        tvs = found
        log("found TVs: " + (found.isEmpty ? "none" : found.map { "\($0.name) (\($0.ip))" }.joined(separator: ", ")))
        onChange?(found)
    }
}
