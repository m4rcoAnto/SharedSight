import Foundation

// Persistent identity of a *registered* person. Deliberately separate from frame-level tracking:
// a `PersonProfile` survives app restarts; a `TrackSnapshot.id` is a session-local trajectory number and
// is never stored as, or promoted to, a person's identity. Bystanders never get a profile.

public enum PersonRole: String, Codable, Sendable, CaseIterable { case assistedPerson, companion }
public enum ProfileStatus: String, Codable, Sendable { case active, archived }

public struct TrackingPreferences: Codable, Equatable, Sendable {
    /// How long the last reliable target position is kept while the person is hidden.
    public var occlusionGraceSeconds: Double
    public var announceStateChanges: Bool
    public init(occlusionGraceSeconds: Double = 1.5, announceStateChanges: Bool = true) {
        self.occlusionGraceSeconds = occlusionGraceSeconds
        self.announceStateChanges = announceStateChanges
    }
}

public struct PersonProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID                 // persistent UUID
    public let userID: String           // human-readable, e.g. USER-0001; never reused after deletion
    public var nickname: String
    public let registeredAt: Date
    public var markerToken: String?     // random token carried by the wearable marker; nil = marker revoked
    public var role: PersonRole
    public var status: ProfileStatus
    public var preferences: TrackingPreferences

    public var displayName: String { nickname.isEmpty ? userID : nickname }
}

/// What the wearable QR marker contains: a version prefix and a random token. No name, no user ID, no UUID.
/// A printed marker can be photographed and copied, so it proves "someone carries this marker", nothing stronger.
public enum MarkerPayload {
    public static let prefix = "SSGT1:"

    public static func encode(token: String) -> String { prefix + token }

    /// Returns the token, or nil when the string is not a Shared Sight target marker.
    public static func decode(_ payload: String) -> String? {
        guard payload.hasPrefix(prefix) else { return nil }
        let token = String(payload.dropFirst(prefix.count))
        guard token.count == 32, token.allSatisfy({ $0.isHexDigit }) else { return nil }
        return token.lowercased()
    }

    /// 128 random bits as 32 hex characters.
    public static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}

// MARK: - Persistence

/// Minimal storage seam so the registry and the event log can be tested without touching the disk.
public protocol BlobPersistence: AnyObject {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func erase() throws
}

public final class InMemoryPersistence: BlobPersistence {
    public private(set) var data: Data?
    public private(set) var saveCount = 0
    public init(data: Data? = nil) { self.data = data }
    public func load() throws -> Data? { data }
    public func save(_ data: Data) throws { self.data = data; saveCount += 1 }
    public func erase() throws { data = nil }
}

/// One JSON file in the app's private container. On iOS it is written with complete file protection,
/// so it is encrypted while the phone is locked. Nothing is sent anywhere.
public final class FilePersistence: BlobPersistence {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    public func erase() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

public enum RegistryError: Error, Equatable { case unknownProfile, corruptStore(String) }

/// Creates, edits, selects and deletes registered people. Not thread-safe: own it from one thread (the main thread).
public final class PersonRegistry {
    private struct Document: Codable {
        var version = 1
        var nextSerial = 1
        var activeProfileID: UUID?
        var profiles: [PersonProfile] = []
    }

    private let persistence: BlobPersistence
    private var document = Document()

    public var profiles: [PersonProfile] { document.profiles }
    public var activeProfileID: UUID? { document.activeProfileID }
    public var activeProfile: PersonProfile? { document.profiles.first { $0.id == document.activeProfileID } }

    /// Loads existing profiles. A missing file is an empty registry; an unreadable one throws instead of
    /// silently starting empty (which would later overwrite the user's data).
    public init(persistence: BlobPersistence) throws {
        self.persistence = persistence
        if let data = try persistence.load() {
            do { document = try Self.decoder.decode(Document.self, from: data) }
            catch { throw RegistryError.corruptStore(String(describing: error)) }
        }
    }

    public func profile(id: UUID) -> PersonProfile? { document.profiles.first { $0.id == id } }
    public func profile(markerToken: String) -> PersonProfile? { document.profiles.first { $0.markerToken == markerToken } }

    public static func formatUserID(serial: Int) -> String { String(format: "USER-%04d", serial) }

    @discardableResult
    public func create(nickname: String, role: PersonRole = .assistedPerson, now: Date = Date()) throws -> PersonProfile {
        let profile = PersonProfile(id: UUID(), userID: Self.formatUserID(serial: document.nextSerial),
                                    nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines), registeredAt: now,
                                    markerToken: MarkerPayload.newToken(), role: role, status: .active,
                                    preferences: TrackingPreferences())
        var next = document
        next.nextSerial += 1            // serials only grow: a deleted person's ID is never handed to someone else
        next.profiles.append(profile)
        if next.activeProfileID == nil { next.activeProfileID = profile.id }
        try commit(next)
        return profile
    }

    /// Applies an edit to the mutable fields. `id`, `userID` and `registeredAt` cannot change (they are `let`).
    @discardableResult
    public func update(id: UUID, _ edit: (inout PersonProfile) -> Void) throws -> PersonProfile {
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else { throw RegistryError.unknownProfile }
        var next = document
        edit(&next.profiles[index])
        try commit(next)
        return next.profiles[index]
    }

    /// Replaces the marker token. Every previously printed marker for this person stops matching.
    @discardableResult
    public func regenerateMarker(id: UUID) throws -> PersonProfile {
        try update(id: id) { $0.markerToken = MarkerPayload.newToken() }
    }

    public func select(id: UUID?) throws {
        if let id, profile(id: id) == nil { throw RegistryError.unknownProfile }
        var next = document
        next.activeProfileID = id
        try commit(next)
    }

    /// Removes the profile and returns it so the caller can erase everything else that referred to it
    /// (tracking events, the live target association).
    @discardableResult
    public func delete(id: UUID) throws -> PersonProfile {
        guard let index = document.profiles.firstIndex(where: { $0.id == id }) else { throw RegistryError.unknownProfile }
        var next = document
        let removed = next.profiles.remove(at: index)
        if next.activeProfileID == id { next.activeProfileID = nil }
        try commit(next)
        return removed
    }

    /// The in-memory state changes only after the write succeeded, so memory and disk cannot disagree.
    private func commit(_ next: Document) throws {
        try persistence.save(try Self.encoder.encode(next))
        document = next
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder = JSONDecoder()
}

// MARK: - Session tracking events (diagnostics)

public struct TrackingEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case acquisitionStarted, acquired, reassociated, following, occluded, ambiguous, lost, stopped, resumedAfterCrossing
    }
    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var userID: String?       // registered person only; bystanders are never recorded
    public var trackID: Int?         // temporary trajectory number of the *target* at that moment
    public var detail: String?

    public init(id: UUID = UUID(), date: Date, kind: Kind, userID: String?, trackID: Int?, detail: String? = nil) {
        self.id = id; self.date = date; self.kind = kind; self.userID = userID; self.trackID = trackID; self.detail = detail
    }
}

public struct RetentionPolicy: Codable, Equatable, Sendable {
    public var maxAgeDays: Double
    public var maxEvents: Int
    public init(maxAgeDays: Double = 7, maxEvents: Int = 1000) { self.maxAgeDays = maxAgeDays; self.maxEvents = maxEvents }
}

/// Local log of target-tracking state changes for testing and diagnostics. Text metadata only: no images,
/// no positions of other people. Old entries are dropped according to `policy`.
public final class TrackingEventLog {
    public var policy: RetentionPolicy { didSet { prune(now: Date()) } }
    public private(set) var events: [TrackingEvent] = []
    private let persistence: BlobPersistence
    private var dirty = false

    public init(persistence: BlobPersistence, policy: RetentionPolicy = RetentionPolicy(), now: Date = Date()) {
        self.persistence = persistence
        self.policy = policy
        if let data = try? persistence.load() {
            events = (try? JSONDecoder().decode([TrackingEvent].self, from: data)) ?? []   // a damaged log is disposable
        }
        prune(now: now)
    }

    public func append(_ event: TrackingEvent) {
        events.append(event)
        dirty = true
        prune(now: max(event.date, Date()))
    }

    public func prune(now: Date) {
        let before = events.count
        let cutoff = now.addingTimeInterval(-policy.maxAgeDays * 86_400)
        events.removeAll { $0.date < cutoff }
        if events.count > policy.maxEvents { events.removeFirst(events.count - policy.maxEvents) }
        if events.count != before { dirty = true }
    }

    /// Erases everything recorded about one registered person (used when their profile is deleted).
    public func purge(userID: String) {
        let before = events.count
        events.removeAll { $0.userID == userID }
        if events.count != before { dirty = true }
    }

    public func clear() { events.removeAll(); dirty = true }

    /// Writes to storage if something changed. Call it at a low rate, not per frame.
    public func flush() {
        guard dirty else { return }
        let encoder = JSONEncoder()
        do {
            if events.isEmpty { try persistence.erase() } else { try persistence.save(try encoder.encode(events)) }
            dirty = false
        } catch { /* keep `dirty`: the next flush retries */ }
    }
}
