//
//  QsibSensorLib.swift
//  QsibSensor
//
//  Created by Jacob Trueb on 11/18/20.
//

import Foundation
import ZIPFoundation

enum MeasurementState {
    case initial
    case running
    case paused
    case ended
}

class QsMeasurement {
    let rs_id: UInt32
    let signalChannels: UInt8
    var sampleCount: UInt64
    var payloadCount: UInt64
    var startStamp: Date?
    var avgEffectivePayloadSize: Float
    var state: MeasurementState

    var graphableTimestamps: [Double]?
    var graphableChannels: [[Double]]?
    
    public init(signalChannels: UInt8) {
        LOGGER.trace("Allocating QsMeasurment with \(signalChannels)")
        self.rs_id = qs_create_measurement(signalChannels)
        self.signalChannels = signalChannels
        self.sampleCount = 0
        self.payloadCount = 0
        self.state = .initial
        self.startStamp = nil
        self.avgEffectivePayloadSize = 0
        LOGGER.trace("Allocated QsMeasurement \(self.rs_id)")
    }
    
    deinit {
        LOGGER.trace("Dropping QsMeasumrent \(self.rs_id)")
        let success = qs_drop_measurement(self.rs_id)
        LOGGER.trace("Dropped QsMeasurement \(self.rs_id) with result \(success)")
    }
    
    public func addPayload(data: Data) -> UInt32? {
//        LOGGER.trace("Adding signals from \(data.prefix(Int(data[0])).hexEncodedString())")
        guard sampleCount < UINT32_MAX - 255 else {
            LOGGER.error("Not enough space to continue allocating samples")
            return nil
        }
        
        guard data.count < 255 else {
            LOGGER.error("Payload buffer is too big to be valid")
            return nil
        }

        let counter = (UInt64(data[4])
                        + (UInt64(data[5]) << (8 * 1))
                        + (UInt64(data[6]) << (8 * 2))
                        + (UInt64(data[7]) << (8 * 3)))
        if counter % 100 == 0 {
            LOGGER.trace("Found \(counter)th payload counter")
        }
        
        let len = min(UInt16(data.count), UInt16(data[0]) + (UInt16(data[1]) << 8))
        
        var samples: UInt32? = nil
        data.withUnsafeBytes({ (buf_ptr: UnsafeRawBufferPointer) in
            let ptr = buf_ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            samples = qs_add_signals(self.rs_id, ptr, UInt16(len))
        })
        
        LOGGER.trace("Added \(String(describing: samples)) samples for \(self.sampleCount) total")
        sampleCount += UInt64(samples ?? 0)
        payloadCount += 1
        
        avgEffectivePayloadSize = (avgEffectivePayloadSize + Float(data.count - (2 + 1 + 4))) / 2
        if state == .running && startStamp == nil {
            startStamp = Date()
        }

        return samples
    }
    
    public func interpretTimestamps(hz: Float32, rateScaler: Float32, targetCardinality: UInt64?) -> (UInt32, [Double])? {
        LOGGER.trace("Interpretting timestamps for QsMeasurement \(self.rs_id) with \(hz) Hz and \(rateScaler) scaler")
        
        guard self.sampleCount < UINT32_MAX else {
            LOGGER.error("Sample count too large to interpret timestamps")
            return nil
        }
        
        var downsampleThreshold: UInt32 = 1
        var downsampleScale: UInt32 = 1
        if let targetCardinality = targetCardinality {
            let samples = self.sampleCount > targetCardinality ? self.sampleCount : targetCardinality
            downsampleScale = 1024 * 1024
            downsampleThreshold = UInt32(UInt64(downsampleScale) * targetCardinality / samples)
        }
        
        let bufSize = UInt32(min(UInt64(pow(2, ceil(log(Double(self.sampleCount)) / log(2)))), UInt64(UINT32_MAX)))
        let timestamps = UnsafeMutablePointer<Double>.allocate(capacity: Int(bufSize))
        let numTimestamps = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        numTimestamps[0] = bufSize
        let success = qs_interpret_timestamps(self.rs_id, hz, rateScaler, 0xDEADBEEF, downsampleThreshold, downsampleScale, timestamps, numTimestamps)
        
        if success {
            LOGGER.trace("Interpretted \(numTimestamps[0]) timestamps for QsMeasurment \(self.rs_id)")
            let stamps = [Double](UnsafeBufferPointer(start: timestamps, count: Int(numTimestamps[0])))
            let num = numTimestamps[0]
            
            timestamps.deallocate()
            numTimestamps.deallocate()
            
            return (num, stamps)
        } else {
            LOGGER.error("Failed to interpret timestamps for QsMeasurement \(self.rs_id)")
            LOGGER.error("QS_LIB error message: \(String(describing: QS_LIB.getError()))")
            
            timestamps.deallocate()
            numTimestamps.deallocate()

            return nil
        }
    }
 
    public func getSignals(targetCardinality: UInt64?) -> (UInt32, [[Double]])? {
        LOGGER.trace("Copying signals for QsMeasurement \(self.rs_id)")
        
        guard self.sampleCount < UINT32_MAX else {
            LOGGER.error("Sample count too large to copy signals")
            return nil
        }
        
        var downsampleThreshold: UInt32 = 1
        var downsampleScale: UInt32 = 1
        if let targetCardinality = targetCardinality {
            let samples = self.sampleCount > targetCardinality ? self.sampleCount : targetCardinality
            downsampleScale = 1024 * 1024
            downsampleThreshold = UInt32(UInt64(downsampleScale) * targetCardinality / samples)
        }
        
        let bufSize = UInt32(min(UInt64(pow(2, ceil(log(Double(self.sampleCount)) / log(2)))), UInt64(UINT32_MAX)))
        
        let channelData = UnsafeMutablePointer<UnsafeMutablePointer<Double>?>.allocate(capacity: Int(self.signalChannels))
        for i in 0..<self.signalChannels {
            channelData[Int(i)] = UnsafeMutablePointer<Double>.allocate(capacity: Int(bufSize))
        }
        let numSamplesPerChannel = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        numSamplesPerChannel[0] = bufSize
        
        let success = qs_copy_signals(self.rs_id, 0xDEADBEEF, downsampleThreshold, downsampleScale, channelData, numSamplesPerChannel)
        if success {
            LOGGER.trace("Copied \(numSamplesPerChannel[0]) samples per channel \(self.signalChannels) for QsMeasurment \(self.rs_id)")
            let channels: [[Double]] = (0..<self.signalChannels).map { channelIndex in
                let v = [Double](UnsafeBufferPointer(start: channelData[Int(channelIndex)]!, count: Int(numSamplesPerChannel[0])))
                channelData[Int(channelIndex)]!.deallocate()
                return v
            }

            channelData.deallocate()
            
            let num = numSamplesPerChannel[0];
            numSamplesPerChannel.deallocate()
            
            return (num, channels)
        } else {
            LOGGER.error("Failed to interpret timestamps for QsMeasurement \(self.rs_id)")
            LOGGER.error("QS_LIB error message: \(String(describing: QS_LIB.getError()))")
            
            channelData.deallocate()
            for i in 0..<self.signalChannels {
                channelData[Int(i)]!.deallocate()
            }
            numSamplesPerChannel.deallocate()
            
            return nil
        }
    }
    
    public func archive(hz: Float, rateScaler: Float) -> URL? {
        LOGGER.debug("Archiving QsMeasurement \(self.rs_id) ...")
        
        guard let (numTimestamps, archivableTimestamps) = self.interpretTimestamps(hz: hz, rateScaler: rateScaler, targetCardinality: nil) else {
            LOGGER.error("Failed to get archivable timestamps")
            return nil
        }
        LOGGER.trace("Retrieved \(numTimestamps) timestamps")

        guard let (numSamplesPerChannel, archivableSignals) = self.getSignals(targetCardinality: nil) else {
            LOGGER.error("Failed to get archivable channel signals")
            return nil
        }
        LOGGER.trace("Retrieved \(numSamplesPerChannel) samples per (\(archivableSignals.count)) channels")

        // Create an csv zip for the data
        let channelHeaders = (0..<archivableSignals.count).map { "Channel\($0)" }.joined(separator: ",")
        let csvData = "TimestampSinceCaptureStart,\(channelHeaders)\n" + zip(archivableTimestamps, (0..<Int(numSamplesPerChannel)))
            .map { (t, i) in
                let channelValues = (0..<archivableSignals.count)
                    .map { archivableSignals[$0][i] }
                    .map { String.init(format: "%.3f", $0) }.joined(separator: ",")
                return "\(t),\(channelValues)"
            }
            .joined(separator: "\n")
        let uncompressedData = csvData.data(using: String.Encoding.utf8)!
        guard let archive = Archive(accessMode: .create) else {
            LOGGER.error("Failed to create in-memory archive")
            return nil
        }
    
        try? archive.addEntry(with: "channels.csv", type: .file, uncompressedSize: UInt32(uncompressedData.count), modificationDate: Date(), permissions: nil, compressionMethod: .deflate, bufferSize: 4096, provider: { (position, size) -> Data in
            uncompressedData.subdata(in: position..<position+size)
        })
        
        
        // Write the zip to a temporary file
        //let directoryUrl = FileManager.default.temporaryDirectory
        let directoryUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        let now = Date()
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateString = formatter.string(from: now)
        let zipFilePath = directoryUrl.appendingPathComponent("MA_data_"+dateString+".zip")
        
        try? FileManager.default.removeItem(at: zipFilePath)
        guard FileManager.default.createFile(atPath: zipFilePath.path, contents: archive.data, attributes: nil) else {
            LOGGER.error("Failed to write archive at \(zipFilePath)")
            return nil
        }
        
        return zipFilePath
    }
}


class QsibSensorLib {
    let initializer: Void = {
        qs_init();
        return ()
    }()
    
    public func getError() -> String? {
        let result = qs_errors_pop();
        if result != nil {
            let string = String(cString: result!)
            qs_errors_drop(result)
            return string
        }
        return nil
    }
}
