import Foundation

/// What the hub's QR code carries: where the hub is, the key it printed, and (optionally) the session code.
public struct HubLink: Equatable, Sendable {
    public var url: String
    public var token: String
    public var session: String?
    public init(url: String, token: String, session: String? = nil) { self.url = url; self.token = token; self.session = session }
}

/// Parser for `sharedsight://hub?url=<percent-encoded http(s) URL>&token=<key>&session=<code>`.
/// Anything else (another app's QR code, a target marker, a web link) is nil and is never stored.
public enum HubLinkPayload {
    public static func parse(_ payload: String) -> HubLink? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = URLComponents(string: text), link.scheme?.lowercased() == "sharedsight",
              link.host?.lowercased() == "hub" else { return nil }
        func value(_ name: String) -> String? {
            link.queryItems?.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Same rules as the transport: plain http(s) address with a host, no credentials, no query, no fragment.
        guard let raw = value("url"), let hub = URLComponents(string: raw),
              let scheme = hub.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = hub.host, !host.isEmpty, hub.user == nil, hub.password == nil,
              hub.query == nil, hub.fragment == nil else { return nil }
        guard let token = value("token"), !token.isEmpty,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        let session = value("session")
        return HubLink(url: raw, token: token, session: session?.isEmpty == false ? session : nil)
    }
}
