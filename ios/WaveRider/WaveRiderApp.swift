import SwiftUI
import UIKit

@main
struct WaveRiderApp: App {
    @StateObject private var ble = BoatBLE()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
        .onChange(of: scenePhase) { phase in
            // app goes to the background or Control Center opens: stop the boat
            if phase != .active { ble.stopNow() }
        }
    }
}

extension Color {
    static let wrBg     = Color(red: 0.043, green: 0.086, blue: 0.133)
    static let wrPanel  = Color(red: 0.075, green: 0.141, blue: 0.227)
    static let wrPanel2 = Color(red: 0.102, green: 0.188, blue: 0.298)
    static let wrLine   = Color(red: 0.153, green: 0.251, blue: 0.373)
    static let wrDim    = Color(red: 0.541, green: 0.643, blue: 0.741)
    static let wrAccent = Color(red: 0.180, green: 0.769, blue: 0.714)
    static let wrBlue   = Color(red: 0.302, green: 0.639, blue: 1.000)
    static let wrWarn   = Color(red: 0.957, green: 0.635, blue: 0.380)
    static let wrStop   = Color(red: 0.902, green: 0.224, blue: 0.275)
    static let wrOk     = Color(red: 0.322, green: 0.824, blue: 0.451)
}

struct PanelButton: ButtonStyle {
    var primary = false
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.vertical, 7)
            .padding(.horizontal, 11)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 10).fill(primary ? Color.wrAccent : Color.wrPanel2))
            .foregroundColor(primary ? Color(red: 0.02, green: 0.15, blue: 0.13) : .white)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
