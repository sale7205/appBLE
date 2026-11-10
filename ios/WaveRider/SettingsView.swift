import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var ble: BoatBLE
    @Environment(\.dismiss) private var dismiss

    // toggles send right away when you flip them (not when the boat sends its settings back)
    func dirBinding(_ key: WritableKeyPath<BoatConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { ble.cfg[keyPath: key] },
            set: { ble.cfg[keyPath: key] = $0; ble.sendDirs() }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Settings").font(.headline)
                Spacer()
                Button("Reload") { ble.send("GET") }.buttonStyle(PanelButton())
                Button("Save to boat") { ble.send("SAVE") }.buttonStyle(PanelButton(primary: true))
                Button("Done") { dismiss() }.buttonStyle(PanelButton())
            }
            .padding(12)
            Divider().background(Color.wrLine)

            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        section("Trim (straight line)")
                        SettingSlider(title: "Trim", value: $ble.cfg.trim, range: -50...50, step: 1,
                                      format: { trimText($0) }) { ble.sendTrim() }
                        Button("Learn trim") { ble.learnTrim() }
                            .buttonStyle(PanelButton(primary: ble.tele.learnReady))
                        hint("Boat pulls right (right motor weak)? slow the LEFT. Easiest: in Manual, drive forward holding the steering that keeps it straight for 3 s, then tap Learn trim. Save when happy.")

                        section("Motors")
                        SettingSlider(title: "PWM_MIN L", value: $ble.cfg.minL, range: 0...200, step: 1,
                                      format: { "\(Int($0))" }) { ble.sendMin() }
                        SettingSlider(title: "PWM_MIN R", value: $ble.cfg.minR, range: 0...200, step: 1,
                                      format: { "\(Int($0))" }) { ble.sendMin() }
                        SettingSlider(title: "Speed limit", value: $ble.cfg.maxPwm, range: 0...255, step: 1,
                                      format: { "\(Int($0))" }) { ble.sendLimit() }
                        SettingSlider(title: "Ramp", value: $ble.cfg.ramp, range: 0...60, step: 1,
                                      format: { "\(Int($0))/20ms" }) { ble.sendSteerShape() }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 8) {
                        section("Steering stick")
                        SettingSlider(title: "Deadzone", value: $ble.cfg.deadzone, range: 0...30, step: 1,
                                      format: { "\(Int($0))%" }) { ble.sendSteerShape() }
                        SettingSlider(title: "Expo", value: $ble.cfg.expo, range: 0...100, step: 1,
                                      format: { "\(Int($0))%" }) { ble.sendSteerShape() }

                        section("Auto mission")
                        SettingSlider(title: "Leg time", value: $ble.cfg.legMs, range: 500...30000, step: 500,
                                      format: { String(format: "%.1fs", $0 / 1000) }) { ble.sendMission() }
                        SettingSlider(title: "Hold time", value: $ble.cfg.holdMs, range: 0...60000, step: 1000,
                                      format: { String(format: "%.0fs", $0 / 1000) }) { ble.sendMission() }
                        SettingSlider(title: "Auto throttle", value: $ble.cfg.autoThr, range: 0...255, step: 1,
                                      format: { "\(Int($0))" }) { ble.sendMission() }

                        section("Directions")
                        Toggle("Reverse left motor", isOn: dirBinding(\.invL))
                        Toggle("Reverse right motor", isOn: dirBinding(\.invR))
                        Toggle("Swap left / right", isOn: dirBinding(\.swapLR))
                    }
                    .frame(maxWidth: .infinity)
                }
                .font(.subheadline)
                .tint(.wrAccent)
                .padding(16)
            }
        }
        .background(Color.wrPanel.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    func section(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1)
            .foregroundColor(.wrAccent)
            .padding(.top, 8)
    }

    func hint(_ s: String) -> some View {
        Text(s).font(.caption).foregroundColor(.wrDim)
    }
}

struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 104, alignment: .leading)
            Slider(value: $value, in: range, step: step, onEditingChanged: { editing in
                if !editing { onCommit() }
            })
            Text(format(value))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundColor(.wrAccent)
                .frame(width: 96, alignment: .trailing)
        }
    }
}

// MARK: - Log + CSV

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct LogView: View {
    @EnvironmentObject var ble: BoatBLE
    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareItem?
    @State private var note = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Log").font(.headline)
                if ble.recording {
                    Text("● \(ble.recCount) rows").font(.caption).foregroundColor(.wrStop)
                }
                if !note.isEmpty {
                    Text(note).font(.caption).foregroundColor(.wrWarn)
                }
                Spacer()
                Button(ble.recording ? "Stop rec" : "Record") { ble.toggleRecording() }
                    .buttonStyle(PanelButton(primary: !ble.recording))
                Button("Export CSV") {
                    if let u = ble.exportCSV() {
                        note = ""
                        share = ShareItem(url: u)
                    } else {
                        note = "Nothing recorded yet"
                    }
                }
                .buttonStyle(PanelButton())
                Button("Clear") { ble.logLines.removeAll() }.buttonStyle(PanelButton())
                Button("Done") { dismiss() }.buttonStyle(PanelButton())
            }
            .padding(12)
            Divider().background(Color.wrLine)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(ble.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
        .background(Color.wrPanel.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(item: $share) { item in
            ActivityView(items: [item.url])
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
