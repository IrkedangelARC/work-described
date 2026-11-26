//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CoreGraphics

/// Persistent monitor inventory — the structured record of every display
/// this machine has seen, keyed by hardware UUID, with roles and an
/// operator-verified layout state. Show-control rule: no automated output
/// routing (windowed capture) until the CURRENT topology has been
/// identified and confirmed by the operator. Any topology change —
/// connect, disconnect, resolution change — invalidates verification.
public enum MonitorInventory {

    public struct Record: Codable, Identifiable {
        public var uuid: String
        public var name: String
        public var lastResolution: String
        public var role: DisplayRole
        public var firstSeen: String
        public var lastSeen: String
        public var notes: String = ""
        public var id: String { uuid }
    }

    public struct Store: Codable {
        public var records: [Record] = []
        public var verifiedFingerprint: String?
        public var verifiedAt: String?
    }

    /// Adopting apps set this at launch to keep their existing inventory
    /// location (Assimilator uses "ArcAssimilator").
    public static var storageFolderName = "ArcDisplayKit"

    public static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent(storageFolderName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("monitor_inventory.json")
    }

    public static func load() -> Store {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(Store.self, from: data)
        else { return Store() }
        return store
    }

    public static func save(_ store: Store) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(store) {
            try? data.write(to: fileURL)
        }
    }

    /// Stable fingerprint of the CURRENT topology: which displays, where,
    /// at what resolution, which is main. Verification binds to this.
    public static func fingerprint(_ snaps: [DisplaySnapshot]) -> String {
        snaps.map {
            "\($0.uuid)@\(Int($0.bounds.origin.x)),\(Int($0.bounds.origin.y)):\(Int($0.bounds.width))x\(Int($0.bounds.height))\($0.isMain ? ":main" : "")"
        }
        .sorted()
        .joined(separator: "|")
    }

    /// Merge the live snapshot into the inventory: update seen displays,
    /// add newcomers (role Auto), leave departed records in place (a known
    /// projector that's unplugged today is still known gear).
    @discardableResult
    public
    static func reconcile(_ snaps: [DisplaySnapshot], stamp: String) -> Store {
        var store = load()
        for s in snaps {
            let res = "\(Int(s.bounds.width))×\(Int(s.bounds.height))"
            if let i = store.records.firstIndex(where: { $0.uuid == s.uuid }) {
                store.records[i].name = s.name
                store.records[i].lastResolution = res
                store.records[i].lastSeen = stamp
            } else {
                store.records.append(Record(
                    uuid: s.uuid, name: s.name, lastResolution: res,
                    role: .auto, firstSeen: stamp, lastSeen: stamp))
            }
        }
        // Verification only survives while the topology is unchanged.
        if store.verifiedFingerprint != fingerprint(snaps) {
            // stays stored but is stale; isVerified() compares live.
        }
        save(store)
        return store
    }

    public static func role(forUUID uuid: String) -> DisplayRole? {
        load().records.first(where: { $0.uuid == uuid })?.role
    }

    public static func setRole(_ role: DisplayRole, forUUID uuid: String, stamp: String) {
        var store = load()
        if let i = store.records.firstIndex(where: { $0.uuid == uuid }) {
            store.records[i].role = role
        } else {
            store.records.append(Record(uuid: uuid, name: "Display", lastResolution: "?",
                                        role: role, firstSeen: stamp, lastSeen: stamp))
        }
        // A role change alters routing intent — require re-confirmation.
        store.verifiedFingerprint = nil
        store.verifiedAt = nil
        save(store)
    }

    /// Operator confirmed the identified layout matches physical reality.
    public static func confirmVerified(_ snaps: [DisplaySnapshot], stamp: String) {
        var store = load()
        store.verifiedFingerprint = fingerprint(snaps)
        store.verifiedAt = stamp
        save(store)
    }

    /// True while the CURRENT topology matches the operator-confirmed one.
    public static func isVerified(_ snaps: [DisplaySnapshot]) -> Bool {
        let store = load()
        return store.verifiedFingerprint == fingerprint(snaps)
    }

    public static func verifiedAt() -> String? { load().verifiedAt }

    public static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }
}
