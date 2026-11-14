import MultipeerConnectivity
import SharedSightCore

/// Local, encrypted peer-to-peer transport (no Internet, no server). Two devices connect only when both
/// users enabled collaboration and entered the same session code. Carries PeerMessage JSON — metadata, never video.
final class MultipeerTransport: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    static let serviceType = "sharedsight"

    var onPeerConnected: ((String) -> Void)?
    var onPeerDisconnected: ((String) -> Void)?
    var onMessage: ((PeerMessage, String) -> Void)?

    private var peerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var code = ""
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func start(sessionCode: String, displayName: String) {
        stop()
        code = sessionCode
        let pid = MCPeerID(displayName: displayName)
        let s = MCSession(peer: pid, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        let adv = MCNearbyServiceAdvertiser(peer: pid, discoveryInfo: ["code": sessionCode], serviceType: Self.serviceType)
        adv.delegate = self
        let br = MCNearbyServiceBrowser(peer: pid, serviceType: Self.serviceType)
        br.delegate = self
        peerID = pid; session = s; advertiser = adv; browser = br
        adv.startAdvertisingPeer()
        br.startBrowsingForPeers()
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil; browser = nil; session = nil; peerID = nil
    }

    func send(_ messages: [PeerMessage], to pid: String? = nil) {
        guard let session, !messages.isEmpty else { return }
        let targets = session.connectedPeers.filter { pid == nil || $0.displayName == pid }
        guard !targets.isEmpty else { return }
        for m in messages {
            guard let data = try? encoder.encode(m) else { continue }
            // Observations are perishable: a late retransmission is worse than a lost packet.
            var mode = MCSessionSendDataMode.reliable
            if case .observations = m { mode = .unreliable }
            try? session.send(data, toPeers: targets, with: mode)
        }
    }

    // MARK: Discovery — only the same session code is ever invited or accepted.

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peer: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard let session, let me = peerID, info?["code"] == code, me.displayName < peer.displayName else { return }
        browser.invitePeer(peer, to: session, withContext: Data(code.utf8), timeout: 10)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peer: MCPeerID) {}

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peer: MCPeerID, withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let accepted = context.map { String(decoding: $0, as: UTF8.self) == code } ?? false
        invitationHandler(accepted && session != nil, session)
    }

    // MARK: MCSessionDelegate

    func session(_ session: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        guard session === self.session else { return }
        switch state {
        case .connected: onPeerConnected?(peer.displayName)
        case .notConnected: onPeerDisconnected?(peer.displayName)
        default: break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        guard session === self.session, let message = try? decoder.decode(PeerMessage.self, from: data) else { return }
        onMessage?(message, peer.displayName)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
