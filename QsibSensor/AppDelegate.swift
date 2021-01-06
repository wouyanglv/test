//
//  AppDelegate.swift
//  QsibSensor
//
//  Created by Jacob Trueb on 11/18/20.
//


import UIKit
import CoreBluetooth
import Foundation
import NIO
import AsyncHTTPClient
import Toast
import Logging

let EVENT_LOOP_GROUP = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount - 1)
let DISPATCH_EVENT_LOOP_GROUP = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let DISPATCH = DISPATCH_EVENT_LOOP_GROUP.next()
var LOGGER = Logger(label: "qsib-sensor")
let FORMATTER = DateFormatter()
let ENCODER = JSONEncoder()
let DECODER = JSONDecoder()
let HTTP_CLIENT = HTTPClient(eventLoopGroupProvider: .shared(EVENT_LOOP_GROUP))
let QS_LIB = QsibSensorLib()
enum DateError : String, Error {
    case invalidDate
}


@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var logger: Logging.Logger!
    var bluetoothDelegate: AppBluetoothDelegate!
    

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Disable Constraint
        UserDefaults.standard.set(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
        
        LOGGER.logLevel = .trace
        FORMATTER.calendar = Calendar(identifier: .iso8601)
        FORMATTER.locale = Locale(identifier: "en_US_POSIX")
        FORMATTER.timeZone = TimeZone(secondsFromGMT: 0)
        DECODER.dateDecodingStrategy = .custom({ (decoder) -> Date in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self) + "Z"

            FORMATTER.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z"
            if let date = FORMATTER.date(from: dateStr) {
                return date
            }
            throw DateError.invalidDate
        })
        
        bluetoothDelegate = AppBluetoothDelegate()
                        
        UserDefaults.standard.register(defaults: [
            "ble_shs_name": ""
        ])
        
        UserDefaults.standard.setValue("", forKey: "ble_shs_name")
        
        ToastManager.shared.isQueueEnabled = true
        
        // Start State bump tick at regular intervals
        TICK()

        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        try? HTTP_CLIENT.syncShutdown()
    }
}

extension UITextField {
    func addDoneCancelToolbar(onDone: (target: Any, action: Selector)? = nil, onCancel: (target: Any, action: Selector)? = nil) {
        let onCancel = onCancel ?? (target: self, action: #selector(cancelButtonTapped))
        let onDone = onDone ?? (target: self, action: #selector(doneButtonTapped))

        let toolbar: UIToolbar = UIToolbar()
        toolbar.barStyle = .default
        toolbar.items = [
            UIBarButtonItem(title: "Cancel", style: .plain, target: onCancel.target, action: onCancel.action),
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: self, action: nil),
            UIBarButtonItem(title: "Done", style: .done, target: onDone.target, action: onDone.action)
        ]
        toolbar.sizeToFit()

        self.inputAccessoryView = toolbar
    }

    // Default actions:
    @objc func doneButtonTapped() { self.resignFirstResponder() }
    @objc func cancelButtonTapped() { self.resignFirstResponder() }
}

extension Date {
    func getElapsedInterval() -> String {
        let interval = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: self, to: Date())

        if let year = interval.year, year > 0 {
            return year == 1 ? "\(year)" + " " + "year ago" :
                "\(year)" + " " + "years ago"
        } else if let month = interval.month, month > 0 {
            return month == 1 ? "\(month)" + " " + "month ago" :
                "\(month)" + " " + "months ago"
        } else if let day = interval.day, day > 0 {
            return day == 1 ? "\(day)" + " " + "day ago" :
                "\(day)" + " " + "days ago"
        } else if let hour = interval.hour, hour > 0 {
            return hour == 1 ? "\(hour)" + " " + "hour ago" :
                "\(hour)" + " " + "hours ago"
        } else if let minute = interval.minute, minute > 0 {
            return minute == 1 ? "\(minute)" + " " + "minute ago" :
                "\(minute)" + " " + "minutes ago"
        } else {
            return "a moment ago"
        }
    }
}

extension Data {
    struct HexEncodingOptions: OptionSet {
        let rawValue: Int
        static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
    }

    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        let format = options.contains(.upperCase) ? "%02hhX" : "%02hhx"
        return map { String(format: format, $0) }.joined()
    }
}

extension String {
    enum ExtendedEncoding {
        case hexadecimal
    }

    func data(using encoding:ExtendedEncoding) -> Data? {
        let hexStr = self.dropFirst(self.hasPrefix("0x") ? 2 : 0)

        guard hexStr.count % 2 == 0 else { return nil }

        var newData = Data(capacity: hexStr.count/2)

        var indexIsEven = true
        for i in hexStr.indices {
            if indexIsEven {
                let byteRange = i...hexStr.index(after: i)
                guard let byte = UInt8(hexStr[byteRange], radix: 16) else { return nil }
                newData.append(byte)
            }
            indexIsEven.toggle()
        }
        return newData
    }
}
