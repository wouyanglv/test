//
//  InspectDataVC.swift
//  QsibSensor
//
//  Created by Jacob Trueb on 11/24/20.
//

import Foundation
import UIKit
import Toast
import ReSwift
import Charts

class ControlCell: UITableViewCell {

    
    
}

class ChannelCell: UITableViewCell, ChartViewDelegate {
    static let COLORS = [
        UIColor.systemBlue,
        UIColor.systemGreen,
        UIColor.systemRed,
        UIColor.systemPurple,
        UIColor.systemPink,
        UIColor.systemTeal,
        UIColor.systemYellow,
        UIColor.systemPink,
        UIColor.systemGray
    ]

    @IBOutlet weak var chartView: LineChartView!
    
    var timestamps: [Double]! = nil
    var channel: [Double]! = nil
    var dataLabel: String! = nil
    var colorIndex: Int! = nil
    
    func updateChartView() {
        self.chartView.xAxis.removeAllLimitLines()
        self.chartView.leftAxis.removeAllLimitLines()
        self.chartView.rightAxis.removeAllLimitLines()
        
        var dataSets: [LineChartDataSet] = []
        for rawData in [zip(timestamps, channel)] {
            let entries: [ChartDataEntry] = rawData.map { ChartDataEntry(x: $0.0, y: $0.1) }
            let color = ChannelCell.COLORS[colorIndex % ChannelCell.COLORS.count]
            let dataSet = LineChartDataSet(entries: entries, label: self.dataLabel)
            dataSet.mode = LineChartDataSet.Mode.linear
            dataSet.axisDependency = .left
            dataSet.setColor(color)
            dataSet.lineWidth = 0
            dataSet.circleRadius = 2
            dataSet.setCircleColor(color)
            dataSets.append(dataSet)
        }
        
        let chartData = LineChartData(dataSets: dataSets)
        chartData.setDrawValues(true)
        
        chartView.data = chartData
        chartView.xAxis.labelPosition = .bottom
        chartView.rightAxis.enabled = false
        chartView.extraLeftOffset = 10.0
        chartView.extraRightOffset = 10.0
        chartView.extraTopOffset = 20.0
        chartView.extraBottomOffset = 20.0
        chartView.dragEnabled = true
        chartView.pinchZoomEnabled = true
        chartView.setScaleEnabled(true)
        chartView.isHidden = false
    }
}

class InspectDataVC: UITableViewController, StoreSubscriber {
    
    var peripheral: QSPeripheral?
    var updateTs = Date()
    
    var cellHeights: [IndexPath: CGFloat] = [:]
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableView.backgroundColor = UIColor.systemGroupedBackground
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        STORE.subscribe(self)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        STORE.unsubscribe(self)
    }
    
    func newState(state: AppState) {
        var updateInfo = false
        if let identifier = state.activePeripheral {
            if let peripheral = state.peripherals[identifier] {
                self.peripheral = peripheral
                updateInfo = true
            }
        }
        
        guard updateInfo else {
            return
        }
        
        guard Date().timeIntervalSince(updateTs) > 1 else {
            return
        }
        updateTs = Date()
        ACTION_DISPATCH(action: RequestUpdateGraphables(peripheral: peripheral!.cbp))

        DispatchQueue.main.async {
            self.tableView.reloadData()
        }
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            return 5
        default:
            return 1
        }
    }
    
    override func numberOfSections(in tableView: UITableView) -> Int {
        1 + (self.peripheral?.signalChannels ?? 0)
    }
    
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        cellHeights[indexPath] = cell.frame.size.height
    }

    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        return cellHeights[indexPath] ?? UITableView.automaticDimension
    }
    
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:
            return "Control"
        default:
            return "Channel \(section - 1)"
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        guard let peripheral = self.peripheral else {
            LOGGER.error("No peripheral to use to start measurement")
            fatalError("No peripheral to use to start measurement")
        }
        
        switch indexPath.section {
        case 0:
            switch indexPath.row {
            case 0:
                LOGGER.debug("Selected turn off device ...")
                ACTION_DISPATCH(action: TurnOffSensor(peripheral: peripheral.cbp))
                self.dismiss(animated: true)
            case 2:
                LOGGER.debug("Selected start measurement ...")
                if let measurementState = self.peripheral?.activeMeasurement?.state {
                    switch measurementState {
                    case .initial:
                        ACTION_DISPATCH(action: StartMeasurement(peripheral: peripheral.cbp))
                    case .paused:
                        ACTION_DISPATCH(action: ResumeMeasurement(peripheral: peripheral.cbp))
                    case .running:
                        ACTION_DISPATCH(action: PauseMeasurement(peripheral: peripheral.cbp))
                    case .ended:
                        LOGGER.debug("Ignoring selection with ended active measurement on \(indexPath)")
                    }
                } else {
                    ACTION_DISPATCH(action: StartMeasurement(peripheral: peripheral.cbp))
                }
            case 3:
                LOGGER.debug("Selected stop measurement ...")
                if let measurementState = self.peripheral?.activeMeasurement?.state {
                    switch measurementState {
                    case .initial:
                        ACTION_DISPATCH(action: StopMeasurement(peripheral: peripheral.cbp))
                    case .paused:
                        ACTION_DISPATCH(action: StopMeasurement(peripheral: peripheral.cbp))
                    case .running:
                        ACTION_DISPATCH(action: StopMeasurement(peripheral: peripheral.cbp))
                    case .ended:
                        LOGGER.debug("Ignoring selection with ended active measurement on \(indexPath)")
                    }
                } else {
                    LOGGER.debug("Ignoring selection without active measurement on \(indexPath)")
                }
            case 4:
                LOGGER.debug("Selected save and export measurement ...")
                if let measurement = peripheral.activeMeasurement,
                    let hz = peripheral.signalHz {
                    
                    LOGGER.debug("Stopping for export from \(measurement.state)")
                    
                    // Pause
                    ACTION_DISPATCH(action: StopMeasurement(peripheral: peripheral.cbp))
                    
                    // Let the user know that we are working on it
                    DispatchQueue.main.async { self.view.makeToastActivity(.center) }
                    
                    DISPATCH.execute {
                        // Archive
                        guard let archive = measurement.archive(hz: Float(hz), rateScaler: 1) else {
                            LOGGER.error("Cannot export archive because archiving failed")
                            return
                        }
                        
                        // AirDrop
                        DispatchQueue.main.async {
                            // Done working remove activity indicator and
                            self.view.hideToastActivity()
                            
                            // Show pop over activity
                            let controller = UIActivityViewController.init(activityItems: [archive], applicationActivities: nil)
                            controller.excludedActivityTypes = [UIActivity.ActivityType.postToTwitter, UIActivity.ActivityType.postToFacebook, UIActivity.ActivityType.postToWeibo, UIActivity.ActivityType.message, UIActivity.ActivityType.print, UIActivity.ActivityType.copyToPasteboard, UIActivity.ActivityType.assignToContact, UIActivity.ActivityType.saveToCameraRoll, UIActivity.ActivityType.addToReadingList, UIActivity.ActivityType.postToFlickr,  UIActivity.ActivityType.postToVimeo, UIActivity.ActivityType.postToTencentWeibo]
                            
                            controller.popoverPresentationController?.sourceView = self.view

                            self.present(controller, animated: true, completion: nil)
                        }
                    }
                } else {
                    LOGGER.debug("Ignoring selection without active measurement on \(indexPath)")
                }
            default:
                LOGGER.debug("Unhandled selection on first section at \(indexPath)")
                break
            }
        default:
            LOGGER.debug("Unhandled selection at \(indexPath)")
            break
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let peripheral = self.peripheral else {
            LOGGER.error("No peripheral to use to populate inspect data")
            self.dismiss(animated: true)
            return tableView.dequeueReusableCell(withIdentifier: "controlcell0")!
        }
        switch indexPath.section {
        case 0:
            let cell = tableView.dequeueReusableCell(withIdentifier: "controlcell0") as! ControlCell
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = "Turn Off Sensor"
                cell.detailTextLabel?.text = ""
            case 1:
                cell.textLabel?.text = "Battery Level"
                cell.detailTextLabel?.text = peripheral.batteryLevel == nil ? "??%" : "\(peripheral.batteryLevel!)%"
            case 2:
                if let measurementState = self.peripheral?.activeMeasurement?.state {
                    switch measurementState {
                    case .initial:
                        cell.textLabel?.text = "Start"
                        cell.detailTextLabel?.text = ""
                    case .paused:
                        cell.textLabel?.text = "Resume"
                        cell.detailTextLabel?.text = ""
                    case .running:
                        cell.textLabel?.text = "Pause"
                        if let startStamp = self.peripheral?.activeMeasurement?.startStamp {
                            let elapsed = Float(Date().timeIntervalSince(startStamp))
                            let effectiveBytes = Float(self.peripheral?.activeMeasurement?.avgEffectivePayloadSize ?? 0.0) * Float(self.peripheral?.activeMeasurement?.payloadCount ?? 0)
                            LOGGER.trace("\(self.peripheral?.activeMeasurement?.payloadCount ?? 0) payloads had \(self.peripheral?.activeMeasurement?.avgEffectivePayloadSize ?? 0.0) effective bytes in \(elapsed) seconds")
                            let rate = Int(effectiveBytes / elapsed)
                            switch rate {
                            case 0...1024:
                                cell.detailTextLabel?.text = "\(rate)B/s"
                            case 1024...(1024*1024):
                                cell.detailTextLabel?.text = "\(Int(rate / 1024))KB/s"
                            case (1024*1024)...:
                                cell.detailTextLabel?.text = "\(Int(rate / 1024 / 1024))MB/s"
                            default:
                                cell.detailTextLabel?.text = nil
                            }
                        }
                    case .ended:
                        cell.textLabel?.text = "... Measurement already ended ..."
                        cell.detailTextLabel?.text = ""
                    }
                } else {
                    cell.textLabel?.text = "Start"
                    cell.detailTextLabel?.text = ""
                }
            case 3:
                cell.textLabel?.text = "End"
                cell.detailTextLabel?.text = nil
            case 4:
                if let measurement = self.peripheral?.activeMeasurement {
                    let numSamplesPerChannel = Int(measurement.sampleCount)
                    let totalSamples: Int = Int(measurement.signalChannels) * numSamplesPerChannel
                    let numBytes = numSamplesPerChannel * 8 + totalSamples * 8; // a little bigger than storage size, not big enough to account for csv size
                    switch numBytes {
                    case 0...1024:
                        cell.detailTextLabel?.text = "\(numBytes)B"
                    case 1024...(1024*1024):
                        cell.detailTextLabel?.text = "\(Int(numBytes / 1024))KB"
                    case (1024*1024)...:
                        cell.detailTextLabel?.text = "\(Int(numBytes / 1024 / 1024))MB"
                    default:
                        cell.detailTextLabel?.text = nil
                    }
                } else {
                    cell.detailTextLabel?.text = nil
                }
                
                cell.textLabel?.text = "Stop, Save, Export"
            default:
                break
            }
            return cell
        default:
            let cell = tableView.dequeueReusableCell(withIdentifier: "channelcell0", for: indexPath) as! ChannelCell
            guard let activeMeasurement = self.peripheral?.activeMeasurement else {
                cell.chartView.data = nil
                return cell
            }
            
            if indexPath.section - 1 > activeMeasurement.signalChannels {
                LOGGER.error("Cannot populate data for channel that the active measurement is not configured to have")
                fatalError("Cannot populate data for channel that the active measurement is not configured to have")
            }
            
            guard let graphableTimestamps = activeMeasurement.graphableTimestamps,
                  let graphableChannels = activeMeasurement.graphableChannels else {
                return cell
            }

            cell.timestamps = graphableTimestamps
            cell.channel = graphableChannels[indexPath.section - 1]
            LOGGER.trace("Updating channel \(indexPath.section - 1) with \(cell.timestamps.count) (\(cell.channel.count)) values")
            cell.dataLabel = "Acceleration (a.u.) [4g = 16384 a.u.]"
            cell.colorIndex = indexPath.section
            cell.chartView.delegate = cell
            cell.updateChartView()
            return cell
        }
    }
}
