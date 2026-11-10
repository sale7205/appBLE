import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var ble: BoatBLE
    @State private var showSettings = false
    @State private var showLog = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.wrBg.ignoresSafeArea()

            VStack(spacing: 8) {
                TopBar(showSettings: $showSettings, showLog: $showLog)
                GeometryReader { geo in
                    HStack(spacing: 8) {
                        ThrottlePanel()
                            .frame(width: geo.size.width * 0.17)
                        CenterPanel()
                            .frame(width: geo.size.width * 0.50)
                        SteerPanel()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if ble.link == .reconnecting {
                Text("Connection lost, reconnecting…")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Capsule().fill(Color.wrStop))
                    .foregroundColor(.white)
                    .padding(.top, 90)
            }

            if let t = ble.toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85)))
                    .foregroundColor(.white)
                    .padding(.top, 48)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: ble.toast)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(ble) }
        .sheet(isPresented: $showLog) { LogView().environmentObject(ble) }
        .alert("Bluetooth is off", isPresented: $ble.bluetoothOff) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Turn on Bluetooth, and allow WaveRider to use it in Settings > Privacy > Bluetooth.")
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var ble: BoatBLE
    @Binding var showSettings: Bool
    @Binding var showLog: Bool

    var dotColor: Color {
        switch ble.link {
        case .connected: return .wrOk
        case .off: return .wrStop
        default: return .wrWarn
        }
    }

    var linkText: String {
        switch ble.link {
        case .off: return "Not connected"
        case .scanning: return "Searching…"
        case .connecting: return "Connecting…"
        case .connected: return ble.deviceName
        case .reconnecting: return "Reconnecting…"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            (Text("Wave").bold() + Text("Rider").bold().foregroundColor(.wrAccent))
                .font(.subheadline)
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 9, height: 9)
                Text(linkText).font(.footnote).lineLimit(1)
                if ble.link == .connected, let r = ble.rssi {
                    Text("\(r) dBm").font(.caption2.monospacedDigit()).foregroundColor(.wrDim)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.wrPanel))

            if ble.tele.watchdog { badge("Watchdog stop") }
            if ble.recording { badge("● REC") }

            Spacer()

            Button("Log") { showLog = true }.buttonStyle(PanelButton())
            Button("Settings") { showSettings = true }.buttonStyle(PanelButton())
            Button(ble.link == .off ? "Connect" : "Disconnect") {
                if ble.link == .off { ble.connect() } else { ble.disconnect() }
            }
            .buttonStyle(PanelButton(primary: true))
        }
        .frame(height: 36)
    }

    func badge(_ s: String) -> some View {
        Text(s)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.23, green: 0.16, blue: 0.08)))
            .foregroundColor(.wrWarn)
    }
}

// MARK: - Throttle (stays where you leave it)

struct ThrottlePanel: View {
    @EnvironmentObject var ble: BoatBLE

    var body: some View {
        VStack(spacing: 6) {
            Text("THROTTLE").font(.caption2).tracking(1).foregroundColor(.wrDim)
            Text(ble.throttle < 0 ? "R \(-ble.throttle)" : "\(ble.throttle)")
                .font(.title2.bold().monospacedDigit())
                .foregroundColor(ble.throttle < 0 ? .wrWarn : .white)

            GeometryReader { geo in
                let h = geo.size.height
                let y = h / 2 - CGFloat(ble.throttle) / 255 * (h / 2)
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 14).fill(Color.wrPanel2)
                    Rectangle().fill(Color.wrLine)
                        .frame(height: 2)
                        .padding(.horizontal, 6)
                        .offset(y: h / 2 - 1)
                    RoundedRectangle(cornerRadius: 14)
                        .fill((ble.throttle < 0 ? Color.wrWarn : Color.wrAccent).opacity(0.55))
                        .frame(height: abs(y - h / 2))
                        .offset(y: min(y, h / 2))
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white)
                        .frame(height: 34)
                        .overlay(Text("\(abs(ble.throttle))").font(.footnote.bold()).foregroundColor(.black))
                        .padding(.horizontal, -6)
                        .shadow(color: .black.opacity(0.5), radius: 5, y: 3)
                        .offset(y: y - 17)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            var v = Int(((h / 2 - g.location.y) / (h / 2) * 255).rounded())
                            v = max(-255, min(255, v))
                            if abs(v) < 14 { v = 0 }      // centre notch
                            ble.throttle = v
                        }
                )
            }
            .frame(width: 64)

            Button("Zero") { ble.throttle = 0 }.buttonStyle(PanelButton(fill: true))
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.wrPanel))
    }
}

// MARK: - Steering (springs back)

struct SteerPanel: View {
    @EnvironmentObject var ble: BoatBLE

    var steerText: String {
        if ble.steer == 0 { return "0" }
        return ble.steer < 0 ? "◀ \(-ble.steer)" : "\(ble.steer) ▶"
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("STEERING").font(.caption2).tracking(1).foregroundColor(.wrDim)
            Text(steerText).font(.title2.bold().monospacedDigit())
            Spacer(minLength: 0)
            GeometryReader { geo in
                let w = geo.size.width
                let knobR: CGFloat = 31
                let x = w / 2 + CGFloat(ble.steer) / 255 * (w / 2 - knobR)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 16).fill(Color.wrPanel2)
                    Rectangle().fill(Color.wrLine)
                        .frame(width: 2)
                        .padding(.vertical, 10)
                        .offset(x: w / 2 - 1)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.wrBlue.opacity(0.7))
                        .frame(width: abs(x - w / 2), height: 9)
                        .offset(x: min(x, w / 2))
                    Circle()
                        .fill(RadialGradient(colors: [.white, Color(red: 0.79, green: 0.84, blue: 0.89)],
                                             center: UnitPoint(x: 0.35, y: 0.3), startRadius: 2, endRadius: 40))
                        .frame(width: knobR * 2, height: knobR * 2)
                        .shadow(color: .black.opacity(0.55), radius: 7, y: 4)
                        .offset(x: x - knobR)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let v = Int(((g.location.x - w / 2) / (w / 2 - knobR) * 255).rounded())
                            ble.steer = max(-255, min(255, v))
                        }
                        .onEnded { _ in ble.steer = 0 }
                )
            }
            .frame(height: 110)
            Spacer(minLength: 0)
            HStack {
                Text("◀ Left")
                Spacer()
                Text("Right ▶")
            }
            .font(.caption)
            .foregroundColor(.wrDim)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.wrPanel))
    }
}

// MARK: - Centre

struct CenterPanel: View {
    @EnvironmentObject var ble: BoatBLE
    @State private var trimWork: DispatchWorkItem?

    var statusText: String {
        guard ble.link == .connected else { return "Not connected" }
        if ble.tele.mode == 1 {
            switch ble.tele.missionState {
            case 1: return "Leg to station \(ble.tele.station) of 5"
            case 2: return "Holding at station \(ble.tele.station)"
            case 3: return "Mission done"
            default: return "Ready: press Start"
            }
        }
        return ble.tele.learnReady ? "Driving straight? tap Learn trim" : "Manual"
    }

    // left arrow = boat goes more left = slow the left motor more (trim +)
    func nudgeTrim(_ d: Double) {
        ble.cfg.trim = max(-50, min(50, ble.cfg.trim.rounded() + d))
        trimWork?.cancel()
        let w = DispatchWorkItem { ble.sendTrim() }
        trimWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                Text("TRIM").font(.caption2).tracking(1).foregroundColor(.wrDim)
                Button { nudgeTrim(1) } label: {
                    Image(systemName: "chevron.left").font(.headline).frame(width: 40, height: 30)
                }
                .buttonStyle(PanelButton())
                Text(trimText(ble.cfg.trim))
                    .font(.title3.bold().monospacedDigit())
                    .frame(maxWidth: .infinity)
                Button { nudgeTrim(-1) } label: {
                    Image(systemName: "chevron.right").font(.headline).frame(width: 40, height: 30)
                }
                .buttonStyle(PanelButton())
                Button("Learn trim") { ble.learnTrim() }
                    .buttonStyle(PanelButton(primary: ble.tele.learnReady))
            }

            PWMBar(label: "L", value: ble.tele.pwmL)
            PWMBar(label: "R", value: ble.tele.pwmR)

            HStack(spacing: 3) {
                ForEach(0..<2) { m in
                    Button {
                        ble.setMode(m)
                    } label: {
                        Text(m == 0 ? "Manual" : "Auto mission")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(ble.tele.mode == m ? Color.wrAccent : Color.clear))
                            .foregroundColor(ble.tele.mode == m ? Color(red: 0.02, green: 0.15, blue: 0.13) : .wrDim)
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.wrPanel2))

            if ble.tele.mode == 1 {
                HStack(spacing: 6) {
                    Button("Start") { ble.send("Q,1") }.buttonStyle(PanelButton(primary: true, fill: true))
                    Button("Arrived") { ble.send("Q,2") }.buttonStyle(PanelButton(fill: true))
                    Button("Next") { ble.send("Q,3") }.buttonStyle(PanelButton(fill: true))
                    Button("Abort") { ble.send("Q,0") }.buttonStyle(PanelButton(fill: true))
                }
            } else {
                HStack(spacing: 8) {
                    Text("Max").font(.caption).foregroundColor(.wrDim)
                    Slider(value: $ble.cfg.maxPwm, in: 0...255, step: 1, onEditingChanged: { editing in
                        if !editing { ble.sendLimit() }
                    })
                    .tint(.wrAccent)
                    Text("\(Int(ble.cfg.maxPwm))").font(.subheadline.monospacedDigit()).frame(width: 34, alignment: .trailing)
                }
            }

            Text(statusText).font(.footnote).foregroundColor(.wrDim)

            Button {
                ble.stopNow()
            } label: {
                Text("STOP")
                    .font(.title2.weight(.heavy))
                    .tracking(3)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.wrStop))
                    .foregroundColor(.white)
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.wrPanel))
    }
}

struct PWMBar: View {
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 14)
            GeometryReader { g in
                let w = g.size.width
                let bw = CGFloat(abs(value)) / 255 * (w / 2)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.wrPanel2)
                    Rectangle().fill(Color.wrBlue)
                        .frame(width: bw)
                        .offset(x: value >= 0 ? w / 2 : w / 2 - bw)
                    Rectangle().fill(Color.wrLine)
                        .frame(width: 2)
                        .offset(x: w / 2 - 1)
                }
                .clipShape(Capsule())
            }
            .frame(height: 16)
            Text("\(value)").font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
        }
    }
}
