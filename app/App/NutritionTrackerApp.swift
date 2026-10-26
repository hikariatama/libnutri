import SwiftUI

@main struct NutritionTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            BootstrapView().preferredColorScheme(.dark).environment(
                \.locale, Locale(identifier: "en_US"))
        }
    }
}

private struct BootstrapView: View {
    @State private var model: AppModel?
    @State private var failed = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if let model {
                SignedInView(model: model)
            } else if failed {
                ContentUnavailableView {
                    Label(
                        "Couldn't open your history",
                        systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Your saved data hasn't been replaced. Try opening it again.")
                } actions: {
                    Button("Try again", action: load).buttonStyle(.glassProminent)
                }
            } else {
                ProgressView("Opening history…")
            }
        }
        .font(AppFont.body).background(Color.appBackground)
        .task { if model == nil && !failed { load() } }
        .onChange(of: scenePhase) { _, phase in model?.setForeground(phase == .active) }
    }
    private func load() {
        do {
            model = try AppModel(repository: SwiftDataRepository())
            failed = false
        } catch { failed = true }
    }
}

private struct SignedInView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.signedIn {
            TodayView(model: model)
        } else {
            VStack(spacing: 24) {
                Image("LibnutriLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 197, height: 53)
                    .accessibilityLabel("libnutri")
                Text("Sign in with libauth to continue")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(action: model.signIn) {
                    HStack {
                        if model.signingIn { ProgressView() }
                        Text(model.signingIn ? "Signing in…" : "Sign in")
                    }.frame(minWidth: 160, minHeight: 40)
                }.buttonStyle(.glassProminent).disabled(model.signingIn)
                if let error = model.authError { ErrorNotice(message: error) }
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(
                Color.appBackground)
        }
    }
}
