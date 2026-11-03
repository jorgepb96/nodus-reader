// SPDX-License-Identifier: AGPL-3.0-only
// Signed Mac peer for the opt-in livePronunciationCloudKitRoundTrip iPhone test.
// Run with a UUID session argument. "probe" as second argument checks access only.
import Foundation
import CloudKit

@main struct PronunciationCloudProbe {
    static func main() async throws {
        setbuf(stdout, nil)
        let session = CommandLine.arguments[1]
        guard let id = UUID(uuidString: session) else { fatalError("A UUID session is required") }
        let cloud = CKContainer(identifier: "iCloud.ai.nodus.reader")
        let status = try await cloud.accountStatus()
        guard status == .available else { throw NSError(domain: "NodusCloudProbe", code: status.rawValue) }
        print("CLOUD PROBE: signed Mac iCloud account available")
        if CommandLine.arguments.last == "probe" { return }
        let database = cloud.privateCloudDatabase
        let zone = CKRecordZone.ID(zoneName: "NodusPronunciationTest-\(session)", ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: "book-\(id.uuidString)", zoneID: zone)
        func waitFor(_ predicate: (CKRecord) -> Bool) async throws -> CKRecord {
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                let record = try await database.record(for: recordID)
                if predicate(record) { return record }
                try await Task.sleep(for: .seconds(2))
            }
            throw NSError(domain: "NodusCloudProbe.Timeout", code: 1)
        }
        _ = try await database.save(CKRecordZone(zoneID: zone))
        do {
            let record = CKRecord(recordType: "Book", recordID: recordID)
            for (key, value) in ["title":"Nodus pronunciation verification", "author":"Test", "format":"txt", "fileName":"probe.txt", "relativePath":"probe.txt", "contentHash":session] { record[key] = value }
            record["fileSize"] = Int64(1)
            record["addedAt"] = Date()
            record["updatedAt"] = Date()
            let data = try JSONSerialization.data(withJSONObject: [["id":UUID().uuidString,"written":"Rocinante","spoken":"Ro si nan te"]], options: [.sortedKeys])
            record["pronunciationsJSON"] = String(decoding: data, as: UTF8.self)
            _ = try await database.save(record)
            print("CLOUD PROBE: Mac published initial pronunciation", session)
            let edited = try await waitFor { ($0["pronunciationsJSON"] as? String)?.contains("Ro thi nan te") == true }
            print("CLOUD PROBE: Mac received iPhone pronunciation edit")
            edited["pronunciationsJSON"] = "[]"
            edited["updatedAt"] = (edited["updatedAt"] as? Date ?? Date()).addingTimeInterval(1)
            _ = try await database.save(edited)
            _ = try await waitFor { $0["title"] as? String == "Nodus verification complete" }
            _ = try await database.deleteRecordZone(withID: zone)
            print("CLOUD PROBE: iPhone acknowledged deletion; temporary zone removed")
        } catch {
            _ = try? await database.deleteRecordZone(withID: zone)
            throw error
        }
    }
}
