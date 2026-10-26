import NutritionCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var spending: SpendStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var apiKey = ""
    @State private var config = AIConfiguration()
    @State private var errorMessage: String?
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var deletionStep = 1
    init(model: AppModel) {
        self.model = model
        self.spending = model.spending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Text(model.profile?.username ?? "").foregroundStyle(.primary)
                    Image("LibnutriLogo")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 118, height: 32)
                        .accessibilityLabel("libnutri")
                    Link(
                        "Passkeys and connected apps",
                        destination: URL(string: "https://libauth.avx.so/account")!)
                    if model.needsImport {
                        Button("Import data from this iPhone") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do { try await model.importLocalMeals() } catch {
                                    errorMessage = TrackerError.normalize(error).message
                                }
                            }
                        }.disabled(saving)
                    }
                    Button("Sign out") {
                        Task {
                            await model.signOut()
                            dismiss()
                        }
                    }
                }
                accountSection
                modelsSection
                errorSection
                Section {
                    Button("Delete all data", role: .destructive) {
                        deletionStep = 1
                        confirmDelete = true
                    }
                    .disabled(saving)
                    .popover(isPresented: $confirmDelete) { deleteConfirmation }
                }
            }
            .font(.body).scrollContentBackground(.hidden).background(Color.appBackground)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                try await model.saveSettings(key: apiKey, config: config)
                                dismiss()
                            } catch { errorMessage = TrackerError.normalize(error).message }
                        }
                    }.disabled(!loaded || saving)
                }
            }
            .task {
                await model.loadCloudSettings()
                await spending.refresh(api: model.api)
                if !loaded { load() }
            }
        }.presentationDragIndicator(.visible)
    }
    private var accountSection: some View {
        Section {
            SecureField(
                model.hasServerKey ? "Saved on server — enter to replace" : "API key", text: $apiKey
            )
            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
            .accessibilityLabel("Openrouter API Key")
            VStack(alignment: .leading, spacing: 12) {
                spendRow("Lifetime spend", amount: spending.amount())
                Divider()
                spendRow("Transcription", amount: spending.amount(.transcription))
                spendRow("Analysis", amount: spending.amount(.analysis))
            }.padding(.vertical, 6)
            if let message = spending.errorMessage {
                ErrorNotice(
                    message: message, actionTitle: "Try again",
                    action: { Task { await spending.refresh(api: model.api) } }, font: .body)
            }
        } header: {
            Text("Openrouter API Key").textCase(nil)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "Your API key is stored encrypted on the server. Audio and food descriptions are sent to OpenRouter and the selected providers."
                )
                Text(
                    "Recorded since \(spending.startedAt.formatted(date: .abbreviated, time: .omitted)). Costs reported by OpenRouter in USD."
                )
                if spending.unknownCount > 0 {
                    Text(
                        "\(spending.unknownCount) request(s) without billing data. The total may be higher."
                    )
                }
            }
        }
    }
    private func spendRow(_ title: String, amount: Decimal) -> some View {
        HStack {
            Text(title).foregroundStyle(title == "Lifetime spend" ? .primary : .secondary)
            Spacer()
            Text(SpendLedger.label(amount)).monospacedDigit().contentTransition(.numericText())
        }.accessibilityElement(children: .combine)
    }
    private var modelsSection: some View {
        Section("Models") {
            VStack(alignment: .leading) {
                Text("Transcription").foregroundStyle(.secondary)
                TextField("Transcription model ID", text: $config.transcriptionModel)
            }
            VStack(alignment: .leading) {
                Text("Nutrition analysis").foregroundStyle(.secondary)
                TextField("Nutrition model ID", text: $config.nutritionModel)
            }
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    @ViewBuilder private var errorSection: some View {
        if let errorMessage {
            Section {
                if loaded {
                    ErrorNotice(message: errorMessage, font: .body)
                } else {
                    ErrorNotice(
                        message: errorMessage, actionTitle: "Try again", action: load, font: .body)
                }
            }
        }
    }
    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(
                deletionStep == 1 ? "Delete all data?" : "Permanently delete everything?",
                systemImage: "trash"
            )
            .font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(
                deletionStep == 1
                    ? "This includes meals, drafts, settings, your API key and spending history."
                    : "This cannot be undone."
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                if deletionStep == 1 {
                    Button("Cancel") { confirmDelete = false }.buttonStyle(.glass)
                    Spacer(minLength: 0)
                    Button("Continue") {
                        withAnimation(reduceMotion ? nil : .snappy) { deletionStep = 2 }
                    }.buttonStyle(.glassProminent).tint(.red)
                } else {
                    Button("Delete", role: .destructive, action: deleteEverything)
                        .buttonStyle(.glassProminent).tint(.red)
                    Spacer(minLength: 0)
                    Button("Keep data") { confirmDelete = false }.buttonStyle(.glass)
                }
            }
        }
        .font(.body).padding(24).frame(idealWidth: 320)
        .presentationCompactAdaptation(.popover)
        .sensoryFeedback(.warning, trigger: deletionStep)
    }
    private func deleteEverything() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.deleteAll()
                apiKey = ""
                config = model.configuration
                confirmDelete = false
                await spending.refresh(api: model.api)
            } catch {
                confirmDelete = false
                errorMessage = TrackerError.normalize(error).message
            }
        }
    }
    private func load() {
        config = model.configuration
        apiKey = ""
        loaded = true
        errorMessage = nil
    }
}
