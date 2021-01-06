//
//  AppStore.swift
//  QsibSensor
//
//  Created by Jacob Trueb on 11/20/20.
//

import CoreBluetooth
import Foundation
import UIKit
import ReSwift
import Toast


struct AppState: StateType {
    var ble: AppBluetoothDelegate? = nil
    var peripherals: [UUID: QSPeripheral] = [:]
    var toastQueue: [ToastMessage] = []
    var activePeripheral: UUID?
}

struct ToastMessage {
    let id = UUID()
    var message: String? = nil
    var duration: TimeInterval = TimeInterval(3)
    var position: ToastPosition = .top
    var title: String? = nil
    var image: UIImage? = nil
    var style: ToastStyle = .init()
    var completion: ((Bool) -> Void)? = nil
}

struct InitBle: Action {
    let delegate: AppBluetoothDelegate
}

struct DidDiscover: Action {
    let peripheral: CBPeripheral
    let rssi: NSNumber
}

struct RequestConnect: Action {
    let peripheral: CBPeripheral
}

struct DidConnect: Action {
    let peripheral: CBPeripheral
}

struct RequestDisconnect: Action {
    let peripheral: CBPeripheral
}

struct DidDisconnect: Action {
    let peripheral: CBPeripheral
}

struct DidFailToConnect: Action {
    let peripheral: CBPeripheral
}

struct DidDiscoverCharacteristic: Action {
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic
}

struct DidUpdateValueForBattery: Action {
    let peripheral: CBPeripheral
    let batteryLevel: UInt8
}

struct DidUpdateValueForSignal: Action {
    let peripheral: CBPeripheral
    let signal: Data
}

struct DidUpdateValueForFirmwareVersion: Action {
    let peripheral: CBPeripheral
    let value: String
}

struct DidUpdateValueForHardwareVersion: Action {
    let peripheral: CBPeripheral
    let value: String
}

struct DidUpdateValueForError: Action {
    let peripheral: CBPeripheral
    let value: String
}

struct DidUpdateValueForName: Action {
    let peripheral: CBPeripheral
    let value: String
}

struct DidUpdateValueForUniqueIdentifier: Action {
    let peripheral: CBPeripheral
    let value: String
}

struct DidUpdateValueForBootCount: Action {
    let peripheral: CBPeripheral
    let value: Int
}

struct WriteControl: Action {
    let peripheral: CBPeripheral
    let control: Data
}

struct WriteHardwareVersion: Action {
    let peripheral: CBPeripheral
    let hardwareVersion: String
}

struct WriteName: Action {
    let peripheral: CBPeripheral
    let name: String
}

struct WriteUniqueIdentifier: Action {
    let peripheral: CBPeripheral
    let uniqueIdentifier: String
}

struct UpdateProjectMode: Action {
    let peripheral: CBPeripheral
    let projectMode: String
}

struct UpdateSignalChannels: Action {
    let peripheral: CBPeripheral
    let channels: Int
}

struct UpdateSignalHz: Action {
    let peripheral: CBPeripheral
    let hz: Int
}

struct StartMeasurement: Action {
    let peripheral: CBPeripheral
}

struct ResumeMeasurement: Action {
    let peripheral: CBPeripheral
}

struct PauseMeasurement: Action {
    let peripheral: CBPeripheral
}

struct StopMeasurement: Action {
    let peripheral: CBPeripheral
}

struct TurnOffSensor: Action {
    let peripheral: CBPeripheral
}

struct RequestUpdateGraphables: Action {
    let peripheral: CBPeripheral
}

struct UpdateGraphableTimestamps: Action {
    let peripheral: CBPeripheral
    let measurement: QsMeasurement
    let timestamps: [Double]
}

struct UpdateGraphableChannels: Action {
    let peripheral: CBPeripheral
    let measurement: QsMeasurement
    let channels: [[Double]]
}


struct AppendToast: Action {
    let message: ToastMessage
}

struct ProcessToast: Action {}

struct Tick: Action {}

func appReducer(action: Action, state: AppState?) -> AppState {
    var state = state ?? AppState()
    
    switch action {
    case _ as ReSwiftInit:
        LOGGER.info("Initializing ReSwift")
    case let action as InitBle:
        state.ble = action.delegate
    case let action as DidDiscover:
        let peripheral = getPeripheral(&state, action.peripheral, rssi: action.rssi)
        peripheral.cbp.delegate = state.ble
    case let action as DidDiscoverCharacteristic:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.add(characteristic: action.characteristic)
        save(&state, peripheral)
    case let action as RequestConnect:
        state.ble?.centralManager.connect(action.peripheral, options: nil)
        state.activePeripheral = action.peripheral.identifier
    case let action as DidConnect:
        let _ = getPeripheral(&state, action.peripheral)
    case let action as RequestDisconnect:
        state.ble?.centralManager.cancelPeripheralConnection(action.peripheral)
    case let action as DidDisconnect:
        let _ = getPeripheral(&state, action.peripheral)
    case let action as DidFailToConnect:
        let _ = getPeripheral(&state, action.peripheral)
    case let action as DidUpdateValueForBattery:
        let peripheral = getPeripheral(&state, action.peripheral)
        LOGGER.trace("\(peripheral.name()) has battery level \(action.batteryLevel)")
        peripheral.batteryLevel = Int(action.batteryLevel)
        save(&state, peripheral)
    case let action as DidUpdateValueForSignal:
        let peripheral = getPeripheral(&state, action.peripheral)
        EVENT_LOOP_GROUP.next().execute {
            guard let measurement = peripheral.activeMeasurement else {
                LOGGER.trace("No active measurement for \(peripheral.id())")
                return
            }
                        
            guard let _ = measurement.addPayload(data: action.signal) else {
                LOGGER.error("Failed to add payload to \(measurement)")
                return
            }
            
            
        }
    case let action as DidUpdateValueForFirmwareVersion:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.firmwareVersion = action.value
        save(&state, peripheral)
    case let action as DidUpdateValueForHardwareVersion:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.hardwareVersion = action.value
        save(&state, peripheral)
    case let action as DidUpdateValueForError:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.error = action.value
        save(&state, peripheral)
        if !action.value.isEmpty {
            LOGGER.warning("Encountered error for \(peripheral)")
        }
    case let action as DidUpdateValueForName:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.persistedName = action.value
        save(&state, peripheral)
    case let action as DidUpdateValueForUniqueIdentifier:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.uniqueIdentifier = action.value
        save(&state, peripheral)
    case let action as DidUpdateValueForBootCount:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.bootCount = action.value
        save(&state, peripheral)
    case let action as WriteControl:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.writeControl(data: action.control)
    case let action as WriteHardwareVersion:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.writeHardwareVersion(value: action.hardwareVersion)
    case let action as WriteName:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.writeName(value: action.name)
    case let action as WriteUniqueIdentifier:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.writeUniqueIdentifier(value: action.uniqueIdentifier)
    case let action as UpdateProjectMode:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.projectMode = action.projectMode
        save(&state, peripheral)
    case let action as UpdateSignalHz:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.signalHz = action.hz
        save(&state, peripheral)
    case let action as UpdateSignalChannels:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.signalChannels = action.channels
        save(&state, peripheral)
    case let action as StartMeasurement:
        let peripheral = getPeripheral(&state, action.peripheral)
        if let numChannels = peripheral.signalChannels {
            peripheral.activeMeasurement = QsMeasurement(signalChannels: UInt8(numChannels))
            peripheral.activeMeasurement?.state = .running
            save(&state, peripheral)
            let data = Data([0x69])
            ACTION_DISPATCH(action: WriteControl(peripheral: action.peripheral, control: data))
        } else {
            LOGGER.error("Number of channels not set. Cannot start measurement")
        }        
    case let action as ResumeMeasurement:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.activeMeasurement?.state = .running
        let data = Data([0x69])
        ACTION_DISPATCH(action: WriteControl(peripheral: action.peripheral, control: data))
    case let action as PauseMeasurement:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.activeMeasurement?.state = .paused
        peripheral.activeMeasurement?.startStamp = nil
        peripheral.activeMeasurement?.payloadCount = 0
        let data = Data([0x00])
        ACTION_DISPATCH(action: WriteControl(peripheral: action.peripheral, control: data))
    case let action as StopMeasurement:
        let peripheral = getPeripheral(&state, action.peripheral)
        if let activeMeasurement = peripheral.activeMeasurement {
            peripheral.activeMeasurement?.state = .ended
            peripheral.activeMeasurement?.startStamp = nil
            peripheral.activeMeasurement?.payloadCount = 0
            peripheral.finalizedMeasurements.append(activeMeasurement)
            peripheral.activeMeasurement = nil
            save(&state, peripheral)
            let data = Data([0x00])
            ACTION_DISPATCH(action: WriteControl(peripheral: action.peripheral, control: data))
        } else {
            LOGGER.trace("No active measurement to stop")
        }
    case let action as TurnOffSensor:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.activeMeasurement?.state = .running
        peripheral.rssi = -100
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF]).prefix(4)
        ACTION_DISPATCH(action: WriteControl(peripheral: action.peripheral, control: data))
    case let action as RequestUpdateGraphables:
        let peripheral = getPeripheral(&state, action.peripheral)
        if let measurement = peripheral.activeMeasurement {
            DISPATCH.execute {
                guard let signalHz = peripheral.signalHz else {
                    LOGGER.error("Cannot interpret timestamps without expected signal hz")
                    return
                }
                
                guard let (_, timestamps) = measurement.interpretTimestamps(hz: Float(signalHz), rateScaler: 1.0, targetCardinality: 1000) else {
                    LOGGER.error("Failed to interpret timestamps for \(measurement)")
                    return
                }
                
                ACTION_DISPATCH(action: UpdateGraphableTimestamps(peripheral: peripheral.cbp, measurement: measurement, timestamps: timestamps))
            }
            
            DISPATCH.execute {
                guard let (_, channelSignals) = measurement.getSignals(targetCardinality: 1000) else {
                    LOGGER.error("Failed to copy measurement signals for \(measurement)")
                    return
                }
                
                ACTION_DISPATCH(action: UpdateGraphableChannels(peripheral: peripheral.cbp, measurement: measurement, channels: channelSignals))
            }
        } else {
            LOGGER.debug("Cannot request update graphables on peripheral without active measurement")
        }
    case let action as UpdateGraphableTimestamps:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.activeMeasurement?.graphableTimestamps = action.timestamps
        saveOften(&state, peripheral)
    case let action as UpdateGraphableChannels:
        let peripheral = getPeripheral(&state, action.peripheral)
        peripheral.activeMeasurement?.graphableChannels = action.channels
        saveOften(&state, peripheral)
    case let action as AppendToast:
        state.toastQueue.append(action.message)
    case _ as ProcessToast:
        state.toastQueue.removeFirst()
    case _ as Tick:
        break
    default:
        LOGGER.warning("Skipped processing \(action)")
    }
    
    return state
}

let STORE = Store<AppState>(
    reducer: appReducer,
    state: nil
)

func ACTION_DISPATCH(action: Action) {
    DISPATCH.execute {
        STORE.dispatch(action)
    }
}

func TICK() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        ACTION_DISPATCH(action: Tick())
        TICK()
    }
}

func getPeripheral(_ state: inout AppState, _ peripheral: CBPeripheral) -> QSPeripheral {
    if let qsp = state.peripherals[peripheral.identifier] {
        qsp.set(peripheral: peripheral)
        state.peripherals[peripheral.identifier] = qsp
        return qsp
    } else {
        fatalError("Encountered unexpected CBPeripheral without discovering advertisement")
    }
}

func getPeripheral(_ state: inout AppState, _ peripheral: CBPeripheral, rssi: NSNumber) -> QSPeripheral {
    if let qsp = state.peripherals[peripheral.identifier] {
        qsp.set(peripheral: peripheral, rssi: rssi)
//        state.peripherals[peripheral.identifier] = qsp
        return qsp
    } else {
        let qsp = QSPeripheral(peripheral: peripheral, rssi: rssi)
        state.peripherals[qsp.id()] = qsp
        return qsp
    }
}

func save(_ state: inout AppState, _ peripheral: QSPeripheral) {
    LOGGER.trace("Saving \(peripheral.id()) ...")
    peripheral.save()
    saveOften(&state, peripheral)
}

func saveOften(_ state: inout AppState, _ peripheral: QSPeripheral) {
//    state.peripherals[peripheral.id()] = peripheral
}

