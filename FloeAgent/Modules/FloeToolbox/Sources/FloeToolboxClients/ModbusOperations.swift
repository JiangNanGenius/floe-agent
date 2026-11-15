import Foundation
import FloeToolboxCore

public enum ModbusValueParser {
    public static func uint8(_ text: String) throws -> UInt8 {
        let value = try uint16(text)
        guard value <= 255 else { throw ClientError.invalidConfiguration }
        return UInt8(value)
    }
    public static func uint16(_ text: String) throws -> UInt16 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 16 else { throw ClientError.invalidConfiguration }
        if trimmed.lowercased().hasPrefix("0x") {
            guard let value = UInt16(trimmed.dropFirst(2),radix:16) else { throw ClientError.invalidConfiguration }
            return value
        }
        guard trimmed.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt16(trimmed) else {
            throw ClientError.invalidConfiguration
        }
        return value
    }
    public static func uint16List(_ text: String) throws -> [UInt16] {
        let parts = try listTokens(text)
        return try parts.map { try uint16($0) }
    }
    public static func boolList(_ text: String) throws -> [Bool] {
        let parts = try listTokens(text)
        return try parts.map { part in
            switch part.lowercased() {
            case "0","off","false","关","否": false
            case "1","on","true","开","是": true
            default: throw ClientError.invalidConfiguration
            }
        }
    }
    private static func listTokens(_ text: String) throws -> [String] {
        let groups = text.split(separator:";",omittingEmptySubsequences:false)
            .flatMap { $0.split(separator:",",omittingEmptySubsequences:false) }
        guard !groups.isEmpty,
              groups.allSatisfy({ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) else {
            throw ClientError.invalidConfiguration
        }
        let tokens = groups.flatMap { $0.split(whereSeparator:\.isWhitespace) }
        guard !tokens.isEmpty else { throw ClientError.invalidConfiguration }
        return tokens.map(String.init)
    }
}

public struct ModbusResolvedOperation: Sendable {
    public let unit: UInt8
    public let address: UInt16
    public let kind: ModbusOperationKind
    public let operation: ModbusOperation
    public let table: ModbusTable
    public let quantity: UInt16
    /// Writable values or read bit values used for a read-back comparison.
    public let expectedValues: [UInt16]
    public let readBack: ModbusOperation?
    public let readBackQuantity: UInt16?
}

/// Editable workbench inputs. `resolve()` is the same validation used before
/// a request is built, so an edited field always changes the exact wire PDU.
public struct ModbusOperationDraft: Sendable, Equatable {
    public var kind: ModbusOperationKind
    public var unitText: String
    public var addressText: String
    public var quantityText: String
    public var valuesText: String
    public var coilOn: Bool
    public var readBack: Bool
    public init(kind: ModbusOperationKind = .readHoldingRegisters,unitText: String = "1",
                addressText: String = "0",quantityText: String = "10",valuesText: String = "0",
                coilOn: Bool = false,readBack: Bool = true) {
        self.kind = kind; self.unitText = unitText; self.addressText = addressText
        self.quantityText = quantityText; self.valuesText = valuesText
        self.coilOn = coilOn; self.readBack = readBack
    }

    public func resolve() throws -> ModbusResolvedOperation {
        let unit = try ModbusValueParser.uint8(unitText)
        let table = kind.table
        let address = try ModbusAddressText.parse(addressText,expected:table).zeroBased
        switch kind {
        case .readCoils, .readDiscreteInputs, .readHoldingRegisters, .readInputRegisters:
            let quantity = try ModbusValueParser.uint16(quantityText)
            guard quantity > 0, Int(quantity) <= kind.maximumQuantity,
                  Int(address)+Int(quantity) <= 65536 else { throw ClientError.invalidConfiguration }
            return ModbusResolvedOperation(unit:unit,address:address,kind:kind,
                operation:.read(function:kind.rawValue,quantity:quantity),table:table,quantity:quantity,
                expectedValues:[],readBack:nil,readBackQuantity:nil)
        case .writeSingleCoil:
            let values: [UInt16] = [coilOn ? 1 : 0]
            return try resolvedWrite(unit:unit,address:address,kind:kind,
                operation:.singleCoil(coilOn),table:table,quantity:1,expectedValues:values,
                readBack:.read(function:1,quantity:1),readBackQuantity:1)
        case .writeSingleRegister:
            let value = try ModbusValueParser.uint16(valuesText)
            return try resolvedWrite(unit:unit,address:address,kind:kind,
                operation:.singleRegister(value),table:table,quantity:1,expectedValues:[value],
                readBack:.read(function:3,quantity:1),readBackQuantity:1)
        case .writeMultipleCoils:
            let bits = try ModbusValueParser.boolList(valuesText)
            guard bits.count <= kind.maximumQuantity, Int(address)+bits.count <= 65536 else {
                throw ClientError.invalidConfiguration
            }
            let values = bits.map { $0 ? UInt16(1) : UInt16(0) }
            return try resolvedWrite(unit:unit,address:address,kind:kind,
                operation:.coils(bits),table:table,quantity:UInt16(bits.count),expectedValues:values,
                readBack:.read(function:1,quantity:UInt16(bits.count)),readBackQuantity:UInt16(bits.count))
        case .writeMultipleRegisters:
            let values = try ModbusValueParser.uint16List(valuesText)
            guard values.count <= kind.maximumQuantity, Int(address)+values.count <= 65536 else {
                throw ClientError.invalidConfiguration
            }
            return try resolvedWrite(unit:unit,address:address,kind:kind,
                operation:.registers(values),table:table,quantity:UInt16(values.count),expectedValues:values,
                readBack:.read(function:3,quantity:UInt16(values.count)),readBackQuantity:UInt16(values.count))
        }
    }
    private func resolvedWrite(unit: UInt8,address: UInt16,kind: ModbusOperationKind,operation: ModbusOperation,
                               table: ModbusTable,quantity: UInt16,expectedValues: [UInt16],
                               readBack: ModbusOperation,readBackQuantity: UInt16) throws -> ModbusResolvedOperation {
        guard Int(address)+Int(quantity) <= 65536 else { throw ClientError.invalidConfiguration }
        return ModbusResolvedOperation(unit:unit,address:address,kind:kind,operation:operation,table:table,
            quantity:quantity,expectedValues:expectedValues,readBack:readBack,readBackQuantity:readBackQuantity)
    }
}
