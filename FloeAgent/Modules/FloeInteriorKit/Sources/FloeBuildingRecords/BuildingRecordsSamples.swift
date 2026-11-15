import Foundation

public struct BuildingRecordsSampleSummary: Codable, Sendable, Hashable {
    public let projectID: ProjectID
    public let revision: Int
    public let roomIDs: [RoomID]
    public let sourceID: SourceID
    public let sourceVersionID: SourceVersionID
    public let bomTargetID: BOMTargetID
    public let bomDraftID: BOMDraftID
    public let bomItemCount: Int
}

/// Synthetic demo data for the upcoming building-records UI. The sample is
/// deliberately bilingual, includes a quoted comma/quote note, one unresolved
/// room, one channel count and separate device/channel/metre/set/package rows.
public enum BuildingRecordsSamples {
    public static let sampleBOMCSV = """
    品牌,型号,数量,单位,房间,楼层,用途,产品名称,通道数,备注
    示例,SW-2G,2,台,客厅,1F,设计需求,智能开关,2,预留零线
    示例,SW-2G,1,台,主卧,1F,采购,智能开关,2,
    示例,MW-1,3,个,客厅,1F,设计需求,窗帘电机,,含 2 m 轨道
    示例,CABLE-2,12.5,米,全屋,,设计需求,总线线缆,,
    示例,SENSOR-T,1,套,厨房,1F,设计需求,温湿度套装,,
    示例,PANEL-6,2,块,厨房,1F,报价,智能面板,6,"含 ""零线"" 版本"
    """

    public static func makeSampleProject(
        at containerURL: URL,
        limits: RecordsLimits = RecordsLimits()
    ) throws -> (store: ProjectRecordsStore, summary: BuildingRecordsSampleSummary) {
        let store = try ProjectRecordsStore.createProject(
            at: containerURL,
            name: "湖畔住宅（示例）",
            limits: limits
        )
        do {
            let summary = try populate(store)
            return (store, summary)
        } catch {
            try? store.close()
            throw error
        }
    }

    /// Populate a newly created project. This is intentionally one-shot: it
    /// refuses a project that already contains rooms so a demo rerun cannot
    /// silently duplicate records.
    @discardableResult
    public static func populate(_ store: ProjectRecordsStore) throws -> BuildingRecordsSampleSummary {
        guard try store.rooms().isEmpty else {
            throw BuildingRecordsError.invalidValue(
                field: "sampleProject",
                reason: "the sample can only populate an empty project"
            )
        }

        var revision = try store.currentRevision()
        let living = try store.createRoom(
            RoomDraft(name: "客厅", storey: "1F", kind: .livingRoom, aliases: ["起居室"]),
            expectedRevision: revision
        )
        revision = living.receipt.revision
        let master = try store.createRoom(
            RoomDraft(name: "主卧", storey: "1F", kind: .bedroom, aliases: ["主卧室"]),
            expectedRevision: revision
        )
        revision = master.receipt.revision
        let kitchen = try store.createRoom(
            RoomDraft(name: "厨房", storey: "1F", kind: .kitchen, aliases: ["中厨"]),
            expectedRevision: revision
        )
        revision = kitchen.receipt.revision
        let dining = try store.createRoom(
            RoomDraft(name: "餐厅", storey: "1F", kind: .dining),
            expectedRevision: revision
        )
        revision = dining.receipt.revision

        let roomIDs = [living.value.id, master.value.id, kitchen.value.id, dining.value.id]
        let sourceResult = try store.importSource(
            SourceImportRequest(
                kind: .table,
                title: "智能家居料单（示例）",
                originalName: "smart-home-bom-sample.csv",
                mediaType: "text/csv",
                data: Data(sampleBOMCSV.utf8),
                note: "Synthetic sample; not a real supplier quotation.",
                roomIDs: roomIDs,
                idempotencyKey: "sample-bom-v1"
            ),
            expectedRevision: revision
        )
        revision = sourceResult.receipt.revision
        let sourceVersionID = sourceResult.value.version.id

        let firstObservation = try store.recordObservation(
            ObservationDraft(
                roomID: kitchen.value.id,
                propertyKey: "room.length_m",
                rawValue: "厨房长度 3.6 m",
                normalizedValue: try RecordedValue(number: 3.6, unit: "m"),
                origin: .user,
                note: "Synthetic user note."
            ),
            expectedRevision: revision
        )
        revision = firstObservation.receipt.revision
        let competingObservation = try store.recordObservation(
            ObservationDraft(
                roomID: kitchen.value.id,
                propertyKey: "room.length_m",
                rawValue: "现场复量 4.0 m",
                normalizedValue: try RecordedValue(number: 4.0, unit: "m"),
                origin: .manualMeasurement,
                note: "Synthetic competing measurement; adoption is explicit."
            ),
            expectedRevision: revision
        )
        revision = competingObservation.receipt.revision
        let adopted = try store.adoptObservation(
            firstObservation.value.id,
            expectedRevision: revision
        )
        revision = adopted.receipt.revision

        let target = try store.createBOMTarget(
            name: "智能家居料单",
            expectedRevision: revision
        )
        revision = target.receipt.revision
        let draft = try store.importBOMDraft(
            csv: Data(sampleBOMCSV.utf8),
            sourceVersionID: sourceVersionID,
            targetID: target.value.id,
            expectedRevision: revision
        )
        revision = draft.receipt.revision
        let applied = try store.applyBOMDraft(
            draft.value.id,
            to: target.value.id,
            expectedRevision: revision
        )
        revision = applied.receipt.revision
        let items = try store.bomItems(targetID: target.value.id, limit: 500)

        return BuildingRecordsSampleSummary(
            projectID: store.projectID,
            revision: revision,
            roomIDs: roomIDs,
            sourceID: sourceResult.value.source.id,
            sourceVersionID: sourceVersionID,
            bomTargetID: target.value.id,
            bomDraftID: draft.value.id,
            bomItemCount: items.count
        )
    }
}
