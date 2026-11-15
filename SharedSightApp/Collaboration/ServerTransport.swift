import Foundation
import QuartzCore
import SharedSightCore

struct RoomPlane: Codable {
    var id: String
    var vertices: [Vec3]
    var triangles: [Int]
    var vertical: Bool
    /// ARKit's own classification when the device provides one: "wall", "door", "window", "floor", "table", "seat", "ceiling".
    var kind: String? = nil
}

/// Apparent size in metres: box extent x measured distance. Present only when the whole box is inside the picture.
struct ObservedSize: Codable {
    var w: Double
    var h: Double
}

struct ServerObservation: Codable {
    var id: Int
    var label: String
    var confidence: Double
    var box: NormRect
    var position: Vec3?
    var sigma: Double?
    var size: ObservedSize? = nil
    var evidence: String = "bearing"
    var measuredAt: Double? = nil
}

/// Protocol v3. Surfaces and the preview travel only when they changed (`planes` / `jpeg` nil = unchanged);
/// `t` and `sent` are on this phone's media clock so the hub can show the capture -> hub delay.
/// A vertical surface met by a depth ray at about chest height: floor position and horizontal normal.
struct ScanHit: Codable {
    var x: Double, z: Double, nx: Double, nz: Double
}

struct ServerFrame: Codable {
    var version = 3
    var receiptToken: String? = nil
    var deviceID: String
    var name: String
    var session: String
    var epoch: String
    var sequence: Int
    var tracking: Bool
    var anchorID: String?
    var camera: Pose?
    var fov: Double?
    var t: Double?
    var sent: Double?
    var planes: [RoomPlane]?
    var objects: [ServerObservation]
    var jpeg: String?
    var scan: [ScanHit]? = nil
}

/// Serialised on the perception queue. One request in flight, no backlog; a new frame retries after failure.
/// The hub's reply to every frame says what this phone cannot see but the shared space knows (see HiddenObjects.swift).
final class ServerTransport {
    /// The hub's latest reply. `anchored` records which frame the positions are in: the shared marker frame (true)
    /// or this phone's own world frame (false), exactly as the frame that was answered.
    struct Advice {
        var advisories: [ServerAdvisory]
        var receivedAt: Timestamp
        var anchored: Bool
        var devices: Int
    }

    private var endpoint: URL?
    private var token = ""
    private var task: URLSessionDataTask?
    private var generation = UUID()
    private var receiptToken: String?
    private var nextSend: Timestamp = 0
    private var lastPlanes: Timestamp = -.infinity
    private var lastPreview: Timestamp = -.infinity
    private(set) var status = "Disconnesso"
    private(set) var advice: Advice?
    /// Round trip of the last answered frame, seconds. Diagnostics only.
    private(set) var roundTrip: Double?

    /// Up to twenty frames per second (one request in flight at a time, so a slow network simply lowers the rate):
    /// the dashboard interpolates between them for continuous motion. Frames are a few hundred bytes.
    let interval = 0.05
    let planesRefresh = 5.0      // surfaces are repeated this often even when unchanged (the hub may have restarted)
    let planesMinGap = 0.5
    let previewInterval = 0.33

    var enabled: Bool { endpoint != nil }
    var ready: Bool { enabled && task == nil && CACurrentMediaTime() >= nextSend }
    /// Whether the next frame should carry the surfaces / a preview picture.
    func planesDue(changed: Bool, now: Timestamp) -> Bool {
        now - lastPlanes >= planesRefresh || (changed && now - lastPlanes >= planesMinGap)
    }
    func previewDue(now: Timestamp) -> Bool { now - lastPreview >= previewInterval }
    /// The surfaces must go with the very next frame (new AR map, or the frame of reference changed).
    func forcePlanes() { lastPlanes = -.infinity }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        config.httpMaximumConnectionsPerHost = 1       // one warm keep-alive connection, no handshake per frame
        return URLSession(configuration: config)
    }()

    func resetEpoch() {
        generation = UUID()
        task?.cancel(); task = nil
        advice = nil; receiptToken = nil; roundTrip = nil
        nextSend = 0; lastPlanes = -.infinity; lastPreview = -.infinity
    }

    func configure(url: String?, token: String) {
        generation = UUID()
        receiptToken = nil
        task?.cancel(); task = nil; endpoint = nil
        self.token = token
        nextSend = 0; lastPlanes = -.infinity; lastPreview = -.infinity
        advice = nil; roundTrip = nil
        guard let url else { status = "Disconnesso"; return }
        guard let base = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(base.scheme?.lowercased() ?? ""), base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              !token.isEmpty else { status = "URL o chiave server non validi"; return }
        endpoint = base.appendingPathComponent("api/frames")
        status = "In connessione…"
    }

    func send(_ frame: ServerFrame, queue: DispatchQueue) {
        guard ready, let endpoint else { return }
        var frame = frame
        let started = CACurrentMediaTime()
        frame.sent = started
        frame.receiptToken = receiptToken
        guard let body = try? JSONEncoder().encode(frame) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let current = generation
        let anchored = frame.anchorID != nil
        let carriedPlanes = frame.planes != nil, carriedPreview = frame.jpeg != nil
        nextSend = started + interval
        task = session.dataTask(with: request) { [weak self] data, response, error in
            queue.async {
                guard let self, self.generation == current else { return }
                self.task = nil
                let now = CACurrentMediaTime()
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error == nil && (code == 200 || code == 204) {
                    self.status = "Connesso"
                    self.roundTrip = now - started
                    if carriedPlanes { self.lastPlanes = started }
                    if carriedPreview { self.lastPreview = started }
                    // 204 = an older hub that does not reply. A malformed reply is ignored, never half-used.
                    if code == 200, let data, let reply = ServerReply.decode(data),
                       reply.matches(epoch: frame.epoch, sequence: frame.sequence) {
                        self.receiptToken = reply.receiptToken
                        // The return leg is at most this request's RTT. Add it only to the uncertainty,
                        // not to the lower bound; local residence is added later by the resolver.
                        let advisories = reply.atReceipt(roundTrip: now - started)
                        self.advice = Advice(advisories: advisories, receivedAt: now, anchored: anchored, devices: reply.devices ?? 1)
                    } else {
                        self.status = "Protocollo server incompatibile o risposta non valida"
                        self.receiptToken = nil
                        self.advice = nil
                    }
                } else {
                    self.status = code == 401 ? "Chiave server errata" : "Server non raggiungibile (\(code)) — nuovo tentativo…"
                    self.nextSend = now + 2
                    self.lastPlanes = -.infinity          // the hub may have restarted: send the surfaces again
                    self.advice = nil                     // nothing the hub said earlier is acted upon any more
                }
            }
        }
        task?.resume()
    }
}
