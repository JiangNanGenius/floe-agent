import Foundation

/// Deterministic header, role and unit vocabulary used by BOM intake. The
/// service keeps the raw header, role cell and unit cell next to the typed
/// value, so an unrecognized alias becomes an issue rather than a guess.
enum BOMColumnAliases {
    static func normalizeToken(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return String(folded.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static let fieldAliases: [BOMField: Set<String>] = [
        .brand: set(["brand", "manufacturer", "make", "vendor", "品牌", "厂家", "厂商", "制造商", "厂牌"]),
        .model: set([
            "model", "modelno", "modelnumber", "partnumber", "partno", "sku", "productmodel",
            "型号", "设备型号", "产品型号", "规格型号", "物料型号", "型号规格"
        ]),
        .orderCode: set([
            "ordercode", "orderno", "catalogcode", "商品编码", "订货号", "订货编码", "货号", "产品编号", "物料编码"
        ]),
        .productName: set([
            "name", "product", "productname", "description", "item", "itemname", "device", "devicename",
            "设备名称", "产品名称", "名称", "设备", "品名", "描述", "物料名称"
        ]),
        .series: set(["series", "productline", "系列", "产品系列"]),
        .quantity: set(["quantity", "qty", "count", "amount", "数量", "台数", "个数", "数目", "用量", "数量合计"]),
        .unit: set(["unit", "uom", "measure", "单位", "计量单位", "单位名称"]),
        .room: set([
            "room", "roomname", "location", "area", "space", "placement",
            "房间", "房间名称", "位置", "安装位置", "区域", "空间", "房间区域"
        ]),
        .storey: set(["floor", "storey", "level", "楼层", "层", "所在楼层", "楼层位置"]),
        .system: set(["system", "subsystem", "系统", "子系统", "专业"]),
        .role: set([
            "role", "bomrole", "listtype", "businessrole",
            "用途", "清单类型", "业务角色", "角色", "清单用途"
        ]),
        .channelsPerDevice: set([
            "channels", "channelcount", "channelsperdevice", "channel",
            "通道数", "通道", "路数", "控制回路数"
        ]),
        .spareQuantity: set(["sparequantity", "spares", "sparecount", "备用数量", "备件数量", "备用数", "备用"]),
        .notes: set(["notes", "note", "remarks", "remark", "comment", "comments", "备注", "说明", "描述备注", "备注说明"])
    ]

    private static func set(_ values: [String]) -> Set<String> {
        Set(values.map(normalizeToken))
    }

    static func field(forNormalizedHeader header: String) -> BOMField? {
        for (field, aliases) in fieldAliases where aliases.contains(header) {
            return field
        }
        return nil
    }

    static let roleAliases: [BOMRole: Set<String>] = [
        .designRequirement: set([
            "design", "designrequirement", "requirement", "required", "planned", "planning",
            "设计", "设计需求", "需求", "方案", "计划"
        ]),
        .quotation: set(["quotation", "quote", "quoted", "estimate", "报价", "报价单", "报价清单", "预算"]),
        .ordered: set([
            "order", "ordered", "purchase", "procurement", "po",
            "采购", "订购", "已下单", "订单", "采购单"
        ]),
        .received: set(["received", "delivery", "delivered", "到货", "已到货", "收货", "已收货"]),
        .installed: set(["installed", "installation", "install", "安装", "已安装", "施工"]),
        .spare: set(["spare", "spares", "backup", "备用", "备件", "备份"]),
        .kitComponent: set([
            "kit", "kitcomponent", "accessory", "accessories", "bundle",
            "套件", "附件", "组件", "套装"
        ]),
        .sourceNote: set(["sourcenote", "note", "remark", "description", "说明", "备注"])
    ]

    static func role(for raw: String) -> BOMRole? {
        let token = normalizeToken(raw)
        guard !token.isEmpty else { return nil }
        for (role, aliases) in roleAliases where aliases.contains(token) {
            return role
        }
        return nil
    }

    static let unitAliases: [BOMQuantityKind: Set<String>] = [
        .devices: set([
            "个", "台", "件", "只", "支", "把", "张", "块", "片",
            "pcs", "pc", "unit", "units", "pieces", "piece", "ea", "each"
        ]),
        .sets: set(["套", "组", "set", "sets", "kit", "kits", "bundle", "bundles"]),
        .channels: set(["通道", "路", "回路", "channel", "channels", "ch"]),
        .metres: set([
            "m", "meter", "meters", "metre", "metres", "米", "延米", "延长米", "米数",
            "lm", "m2", "平方米", "平米"
        ]),
        .packages: set([
            "包", "箱", "盒", "卷", "package", "packages", "pack", "packs", "box", "boxes", "roll", "rolls"
        ])
    ]

    static func quantityKind(for rawUnit: String) -> BOMQuantityKind? {
        let token = normalizeToken(rawUnit)
        guard !token.isEmpty else { return nil }
        for (kind, aliases) in unitAliases where aliases.contains(token) {
            return kind
        }
        return nil
    }

    /// Parses a plain decimal or thousands-grouped decimal. A single comma is
    /// treated as grouping only when it is followed by exactly three digits; the
    /// reader does not guess locale-specific decimal commas.
    static func parseNumber(_ raw: String) -> Double? {
        let compact = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return nil }
        if let direct = Double(compact), direct.isFinite {
            return direct
        }

        var sign = ""
        var body = compact
        if body.hasPrefix("+") || body.hasPrefix("-") {
            sign = String(body.first!)
            body.removeFirst()
        }
        guard !body.isEmpty else { return nil }

        let decimalParts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard decimalParts.count <= 2 else { return nil }
        let integerPart = String(decimalParts[0])
        let fractionPart = decimalParts.count == 2 ? String(decimalParts[1]) : nil
        guard !integerPart.isEmpty else { return nil }
        if let fractionPart, fractionPart.isEmpty || !fractionPart.allSatisfy({ $0.isNumber }) {
            return nil
        }

        var ungroupedInteger = integerPart
        if integerPart.contains(",") {
            let groups = integerPart.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard groups.count >= 2,
                  let first = groups.first, !first.isEmpty, first.allSatisfy({ $0.isNumber }),
                  groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy({ $0.isNumber }) }) else {
                return nil
            }
            ungroupedInteger = groups.joined()
        } else if !integerPart.allSatisfy({ $0.isNumber }) {
            return nil
        }

        let canonical = sign + ungroupedInteger + (fractionPart.map { "." + $0 } ?? "")
        guard let value = Double(canonical), value.isFinite else { return nil }
        return value
    }

    /// Accepts `2`, `2 台` and `2个` and returns the numeric part plus a unit
    /// suffix when present. It never invents a numeric value from text.
    static func parseQuantityAndSuffix(_ raw: String) -> (value: Double, suffix: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = parseNumber(trimmed) {
            return (value, nil)
        }

        let characters = Array(trimmed)
        var index = 0
        if index < characters.count, characters[index] == "+" || characters[index] == "-" {
            index += 1
        }
        let numberStart = index
        while index < characters.count {
            let character = characters[index]
            if character.isNumber || character == "." || character == "," {
                index += 1
            } else {
                break
            }
        }
        guard index > numberStart else { return nil }
        let numberText = String(characters[0..<index])
        let suffix = String(characters[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty, let value = parseNumber(numberText) else { return nil }
        return (value, suffix)
    }

    static func parseChannels(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = Int(trimmed) {
            return value
        }
        let characters = Array(trimmed)
        var index = 0
        while index < characters.count, characters[index].isNumber {
            index += 1
        }
        guard index > 0, let value = Int(String(characters[0..<index])) else { return nil }
        return value
    }

    static func normalizedRoomName(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func keyComponent(_ value: String?) -> String {
        guard let value else { return "-" }
        let token = normalizeToken(value)
        return token.isEmpty ? "-" : token
    }
}
