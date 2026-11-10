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

            if ble.link == .connected && !ble.tele.imuOk { badge("No IMU") }
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
    let modeNames = ["Manual", "Assist", "Auto"]

    var errorDeg: Double {
        var e = ble.tele.target - ble.tele.heading
        while e > 180 { e -= 360 }
        while e < -180 { e += 360 }
        return e
    }

    var missionText: String {
        guard ble.tele.mode == 2 else { return "-" }
        switch ble.tele.missionState {
        case 1: return "Leg to \(ble.tele.station)"
        case 2: return "Holding \(ble.tele.station)"
        case 3: return "Done"
        default: return "Idle"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                CompassView(heading: ble.tele.heading, target: ble.tele.target)
                    .frame(width: 92, height: 92)
                VStack(alignment: .leading, spacing: 1) {
                    readout("Heading", String(format: "%.1f°", ble.tele.heading), .white, big: true)
                    readout("Target", String(format: "%.1f°", ble.tele.target), .wrWarn, big: true)
                    readout("Error", String(format: "%.1f°", errorDeg), .white)
                    readout("Station", ble.tele.station > 0 ? "\(ble.tele.station) / 5" : "-", .white)
                    readout("Mission", missionText, .wrDim)
                }
            }

            PWMBar(label: "L", value: ble.tele.pwmL)
            PWMBar(label: "R", value: ble.tele.pwmR)

            HStack(spacing: 3) {
                ForEach(0..<3) { m in
                    Button {
                        ble.setMode(m)
                    } label: {
                        Text(modeNames[m])
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(ble.tele.mode == m ? Color.wrAccent : Color.clear))
                            .foregroundColor(ble.tele.mode == m ? Color(red: 0.02, green: 0.15, blue: 0.13) : .wrDim)
                    }
                    .opacity(!ble.tele.imuOk && m != 0 ? 0.45 : 1)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.wrPanel2))

            if ble.tele.mode == 2 {
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

            Button {
                ble.stopNow()
            } label: {
                Text("STOP")
                    .font(.title2.weight(.heavy))
                    .tracking(3)
                    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.wrStop))
                    .foregroundColor(.white)
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.wrPanel))
    }

    func readout(_ name: String, _ value: String, _ color: Color, big: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).foregroundColor(.white).frame(width: 54, alignment: .leading)
            Text(value)
                .font(big ? .subheadline.bold().monospacedDigit() : .caption.monospacedDigit())
                .foregroundColor(color)
        }
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
            .frame(height: 12)
            Text("\(value)").font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - Compass

struct CompassView: View {
    let heading: Double
    let target: Double

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            ZStack {
                Circle().fill(Color(red: 0.055, green: 0.11, blue: 0.18))
                Circle().stroke(Color.wrLine, lineWidth: 2)
                ForEach(0..<24) { i in
                    Rectangle()
                        .fill(Color(red: 0.23, green: 0.35, blue: 0.47))
                        .frame(width: i % 6 == 0 ? 2 : 1, height: i % 6 == 0 ? 9 : 5)
                        .offset(y: -s / 2 + (i % 6 == 0 ? 6.5 : 4.5))
                        .rotationEffect(.degrees(Double(i) * 15))
                }
                Text("0").font(.system(size: 9)).foregroundColor(.wrDim).offset(y: -s / 2 + 18)
                Text("90").font(.system(size: 9)).foregroundColor(.wrDim).offset(x: s / 2 - 20)
                Text("-90").font(.system(size: 9)).foregroundColor(.wrDim).offset(x: -s / 2 + 20)
                Text("180").font(.system(size: 9)).foregroundColor(.wrDim).offset(y: s / 2 - 18)
                InwardTriangle()
                    .fill(Color.wrWarn)
                    .frame(width: 11, height: 10)
                    .offset(y: -s / 2 + 5)
                    .rotationEffect(.degrees(target))
                BoatArrow()
                    .fill(Color.wrAccent)
                    .overlay(BoatArrow().stroke(Color.white, lineWidth: 1))
                    .frame(width: s * 0.28, height: s * 0.6)
                    .rotationEffect(.degrees(heading))
            }
            .frame(width: s, height: s)
        }
    }
}

struct InwardTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct BoatArrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.82))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
