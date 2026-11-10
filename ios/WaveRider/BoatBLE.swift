import Foundation
import CoreBluetooth
import UIKit

struct BoatConfig {
    var trim: Double = 0
    var minL: Double = 60
    var minR: Double = 60
    var maxPwm: Double = 255
    var deadzone: Double = 5
    var expo: Double = 30
    var ramp: Double = 10
    var invL = false
    var invR = false
    var swapLR = false
    var legMs: Double = 4000
    var holdMs: Double = 12000
    var autoThr: Double = 180
}

struct Telemetry {
    var pwmL: Int = 0
    var pwmR: Int = 0
    var mode: Int = 0          // 0 Manual, 1 Auto mission
    var station: Int = 0
    var missionState: Int = 0  // 0 idle, 1 leg, 2 holding, 3 done
    var joyActive = false
    var watchdog = false
    var learnReady = false
}

/// + slows the left motor, - slows the right motor
func trimText(_ t: Double) -> String {
    let v = Int(t.rounded())
    if v == 0 { return "0" }
    return v > 0 ? "Left -\(v)%" : "Right -\(-v)%"
}

enum LinkState {
    case off, scanning, connecting, connected, reconnecting
}

final class BoatBLE: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID      = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")  // phone writes
    static let txUUID      = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")  // boat notifies
    static let namePrefix  = "WR-"

    @Published var link: LinkState = .off
    @Published var deviceName = ""
    @Published var rssi: Int?
    @Published var tele = Telemetry()
    @Published var cfg = BoatConfig()
    @Published var logLines: [String] = []
    @Published var toast: String?
    @Published var bluetoothOff = false

    // sticks, set by the UI
    @Published var throttle: Int = 0     // -255..255, stays where you leave it
    @Published var steer: Int = 0        // -255..255, springs back

    // recording
    @Published var recording = false
    @Published var recCount = 0
    private var recRows: [String] = []
    private var recStart = Date()

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var userDisconnect = false
    private var sendTimer: Timer?
    private var rssiTimer: Timer?
    private var toastWork: DispatchWorkItem?

    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notice = UINotificationFeedbackGenerator()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.sendStick() }
        RunLoop.main.add(t, forMode: .common)
        sendTimer = t
        let r = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.link == .connected else { return }
            self.peripheral?.readRSSI()
        }
        RunLoop.main.add(r, forMode: .common)
        rssiTimer = r
    }

    // MARK: connect / disconnect

    func connect() {
        userDisconnect = false
        guard central.state == .poweredOn else {
            bluetoothOff = true
            return
        }
        link = .scanning
        central.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.link == .scanning else { return }
            self.central.stopScan()
            self.link = .off
            self.showToast("Boat not found. Is it powered on?")
        }
    }

    func disconnect() {
        userDisconnect = true
        central.stopScan()
        if let p = peripheral {
            write("S", withResponse: false)
            central.cancelPeripheralConnection(p)
        }
        link = .off
        throttle = 0
        steer = 0
    }

    // MARK: sending

    func send(_ s: String) {
        write(s, withResponse: true)
    }

    func stopNow() {
        throttle = 0
        steer = 0
        if link == .connected { heavy.impactOccurred() }
        write("S", withResponse: true)
    }

    func setMode(_ m: Int) {
        tele.mode = m
        send("M,\(m)")
    }

    func sendTrim()      { send("T,\(Int(cfg.trim))") }
    func learnTrim()     { send("LT") }
    func sendMin()       { send("N,\(Int(cfg.minL)),\(Int(cfg.minR))") }
    func sendLimit()     { send("V,\(Int(cfg.maxPwm))") }
    func sendSteerShape()    { send("D,\(Int(cfg.deadzone)),\(Int(cfg.expo)),\(Int(cfg.ramp))") }
    func sendMission()   { send("E,\(Int(cfg.legMs)),\(Int(cfg.holdMs)),\(Int(cfg.autoThr))") }
    func sendDirs() {
        send("I,\(cfg.invL ? 1 : 0),\(cfg.invR ? 1 : 0),\(cfg.swapLR ? 1 : 0)")
    }

    private func sendStick() {
        guard link == .connected else { return }
        write("J,\(throttle),\(steer)", withResponse: false)
    }

    private func write(_ s: String, withResponse: Bool) {
        guard let p = peripheral, let c = rxChar, p.state == .connected,
              let data = s.data(using: .utf8) else { return }
        if !withResponse && c.properties.contains(.writeWithoutResponse) {
            if p.canSendWriteWithoutResponse {
                p.writeValue(data, for: c, type: .withoutResponse)
            }
        } else {
            p.writeValue(data, for: c, type: .withResponse)
        }
    }

    // MARK: receiving

    private func handle(line raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return }
        if line.hasPrefix("H,") {
            let p = line.dropFirst(2).split(separator: ",").map { Int(String($0)) ?? 0 }
            guard p.count >= 7 else { return }
            var t = Telemetry()
            t.pwmL = p[0]
            t.pwmR = p[1]
            t.mode = p[2]
            t.station = p[3]
            t.missionState = p[4]
            t.joyActive = (p[5] & 1) != 0
            t.watchdog = (p[5] & 2) != 0
            t.learnReady = (p[5] & 4) != 0
            tele = t
            if Double(p[6]) != cfg.trim { cfg.trim = Double(p[6]) }
            if recording {
                let time = String(format: "%.2f", Date().timeIntervalSince(recStart))
                recRows.append("\(time),\(t.pwmL),\(t.pwmR),\(t.mode),\(t.station),\(t.missionState),\(Int(cfg.trim)),\(throttle),\(steer)")
                recCount = recRows.count
            }
            return
        }
        if line.hasPrefix("CFG,") {
            let p = line.dropFirst(4).split(separator: ",").map { Double(String($0)) ?? 0 }
            guard p.count >= 13 else { return }
            var c = BoatConfig()
            c.trim = p[0]
            c.minL = p[1]; c.minR = p[2]; c.maxPwm = p[3]
            c.deadzone = p[4]; c.expo = p[5]; c.ramp = p[6]
            c.invL = p[7] != 0; c.invR = p[8] != 0; c.swapLR = p[9] != 0
            c.legMs = p[10]; c.holdMs = p[11]; c.autoThr = p[12]
            cfg = c
            addLog("Settings loaded from boat")
            return
        }
        addLog(line)
        showToast(line)
    }

    func addLog(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logLines.insert("\(f.string(from: Date()))  \(s)", at: 0)
        if logLines.count > 400 { logLines.removeLast() }
    }

    func showToast(_ s: String) {
        toast = s
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: w)
    }

    // MARK: recording

    func toggleRecording() {
        recording.toggle()
        if recording {
            recRows = []
            recCount = 0
            recStart = Date()
            addLog("Recording started")
        } else {
            addLog("Recording stopped, \(recRows.count) rows")
        }
    }

    func exportCSV() -> URL? {
        guard !recRows.isEmpty else { return nil }
        let header = "time_s,pwm_left,pwm_right,mode,station,mission_state,trim_pct,throttle_cmd,steer_cmd\n"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("waverider_\(f.string(from: Date())).csv")
        do {
            try (header + recRows.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            showToast("Could not write CSV")
            return nil
        }
    }
}

// MARK: - CoreBluetooth

extension BoatBLE: CBCentralManagerDelegate, CBPeripheralDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothOff = (central.state == .poweredOff || central.state == .unauthorized)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        guard name.hasPrefix(BoatBLE.namePrefix) else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        deviceName = name
        rssi = RSSI.intValue
        link = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BoatBLE.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if userDisconnect { link = .off; return }
        link = .reconnecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        rxChar = nil
        throttle = 0
        steer = 0
        if userDisconnect {
            link = .off
            return
        }
        link = .reconnecting
        notice.notificationOccurred(.error)
        addLog("Connection lost")
        central.connect(peripheral, options: nil)   // iOS keeps trying until the boat is back in range
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == BoatBLE.serviceUUID }) else {
            showToast("UART service not found on the boat")
            return
        }
        peripheral.discoverCharacteristics([BoatBLE.rxUUID, BoatBLE.txUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == BoatBLE.rxUUID { rxChar = c }
            if c.uuid == BoatBLE.txUUID { peripheral.setNotifyValue(true, for: c) }
        }
        guard rxChar != nil else { return }
        throttle = 0
        steer = 0
        link = .connected
        notice.notificationOccurred(.success)
        addLog("Connected to \(deviceName)")
        send("GET")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BoatBLE.txUUID, let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else { return }
        for line in text.components(separatedBy: CharacterSet.newlines) {
            handle(line: line)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil { rssi = RSSI.intValue }
    }
}
