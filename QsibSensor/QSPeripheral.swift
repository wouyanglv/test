//
//  QSPeripheral.swift
//  QsibSensor
//
//  Created by Jacob Trueb on 11/23/20.
//

import Foundation
import CoreBluetooth
import Toast

class QSPeripheralCodableState: Codable {
    var projectMode: String?
    var signalHz: Int?
    var signalChannels: Int?
    
    var firmwareVersion: String?
    var hardwareVersion: String?
    var persistedName: String?
    var uniqueIdentifier: String?
        
    init(
        _ projectMode: String?,
        _ signalHz: Int?,
        _ signalChannels: Int?,
        
        _ firmwareVersion: String?,
        _ hardwareVersion: String?,
        _ persistedName: String?,
        _ uniqueIdentifier: String?
    ) {
        self.projectMode = projectMode
        self.signalHz = signalHz
        self.signalChannels = signalChannels
        
        self.firmwareVersion = firmwareVersion
        self.hardwareVersion = hardwareVersion
        self.persistedName = persistedName
        self.uniqueIdentifier = uniqueIdentifier
    }
}

class QSPeripheral {
    var cbp: CBPeripheral!
    var characteristics: [UUID: CBCharacteristic]!
    var peripheralName: String!
    var rssi: Int!
    var ts: Date!
    
    var batteryLevel: Int?
    
    var projectMode: String?
    var signalHz: Int?
    var signalChannels: Int?
    
    var firmwareVersion: String?
    var hardwareVersion: String?
    var error: String?
    var persistedName: String?
    var uniqueIdentifier: String?
    var bootCount: Int?
    
    var activeMeasurement: QsMeasurement?
    var finalizedMeasurements: [QsMeasurement] = []
    
    public init(peripheral: CBPeripheral, rssi: NSNumber) {
        self.set(peripheral: peripheral, rssi: rssi)
        self.characteristics = [:]
        self.ts = Date()
        
        guard let encoded = UserDefaults.standard.data(forKey: id().uuidString) else {
            return
        }
        
        let decoder = JSONDecoder()
        guard let state = try? decoder.decode(QSPeripheralCodableState.self, from: encoded) else {
            LOGGER.error("Failed to decode state for \(id())")
            return
        }
        
        LOGGER.debug("Loaded coded state for \(id()): \(state)")
        
        projectMode = state.projectMode
        signalHz = state.signalHz
        signalChannels = state.signalChannels
        firmwareVersion = state.firmwareVersion
        hardwareVersion = state.hardwareVersion
        persistedName = state.persistedName
        uniqueIdentifier = state.uniqueIdentifier

    }
    
    public func save() {
        let state = QSPeripheralCodableState(
            projectMode,
            signalHz,
            signalChannels,
            firmwareVersion,
            hardwareVersion,
            persistedName,
            uniqueIdentifier)
        
        if let json = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(json, forKey: id().uuidString)
        } else {
            LOGGER.error("Failed to issue state save for \(id())")
        }
    }
    
    public func id() -> UUID {
        return cbp.identifier
    }
    
    public func name() -> String {
        guard let name = persistedName else {
            return self.peripheralName
        }
        return name
    }
    
    public func set(peripheral: CBPeripheral) {
        self.cbp = peripheral
        self.peripheralName = peripheral.name ?? "Unknown"
        self.ts = Date()
    }
    
    public func set(peripheral: CBPeripheral, rssi: NSNumber) {
        self.rssi = Int(truncating: rssi)
        set(peripheral: peripheral)
    }
    
    public func add(characteristic: CBCharacteristic) {
        self.characteristics[UUID(uuidString: characteristic.uuid.uuidString)!] = characteristic
        self.ts = Date()
    }
    
    public func displayRssi() -> Optional<Int> {
        if Date().timeIntervalSince(ts) > 10 {
            return nil
        }
        return rssi
    }

    public func writeControl(data: Data) {
        writeDataToChar(cbuuid: QSS_CONTROL_UUID, data: data)
    }
    
    public func writeHardwareVersion(value: String) {
        writeStringToChar(cbuuid: QSS_HARDWARE_VERSION_UUID, value: value)
    }
    
    public func writeName(value: String) {
        writeStringToChar(cbuuid: QSS_NAME_UUID, value: value)
    }

    public func writeUniqueIdentifier(value: String) {
        writeStringToChar(cbuuid: QSS_UUID_UUID, value: value)
    }
    
    private func writeStringToChar(cbuuid: CBUUID, value: String) {
        writeDataToChar(cbuuid: cbuuid, data: Data(value.utf8))
    }
    
    private func writeDataToChar(cbuuid: CBUUID, data: Data) {
        if let characteristic = self.characteristics[UUID(uuidString: cbuuid.uuidString)!] {
            self.cbp.writeValue(data, for: characteristic, type: .withResponse)
        } else {
            ACTION_DISPATCH(action: AppendToast(message: ToastMessage(message: "Cannot update characteristic", duration: TimeInterval(2), position: .center, title: "Internal BLE Error", image: nil, style: ToastStyle(), completion: nil)))
        }
    }

}
