import NutritionCore
import SwiftUI
import UIKit

struct TextInputView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var settings = false
    private var processing: Bool { model.composerBusy }
    private var label: String {
        if let id = model.snapshot.composer.entryID, model.engine.waitingUntil[id] != nil {
            return "Waiting to retry"
        }
        return model.composerEntry?.phase == .saving ? "Saving" : "Analyzing"
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TextField(
                        "Log food…",
                        text: Binding(get: { model.composerText }, set: model.setComposer),
                        axis: .vertical
                    )
                    .lineLimit(4...12).focused($focused).disabled(processing)
                    .padding(18).glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .accessibilityLabel("Food description")
                    Button {
                        focused = false
                        if processing { model.cancelComposer() } else { model.submit() }
                    } label: {
                        HStack(spacing: 12) {
                            if processing {
                                ProgressView()
                                Text(label)
                                Spacer()
                                Image(systemName: "xmark")
                            } else {
                                Spacer()
                                Label("Send", systemImage: "arrow.up")
                                Spacer()
                            }
                        }.frame(minHeight: 42).padding(.horizontal, 10)
                    }.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                        .disabled(
                            !processing
                                && model.composerText.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                        )
                        .accessibilityLabel(
                            processing ? "Cancel \(label.lowercased())" : "Analyze meal")
                    ComposerError(
                        model: model, settingsAction: { settings = true },
                        editAction: { focused = true })
                }.padding(24)
            }
            .background(Color.appBackground)
            .navigationTitle("Log food").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        model.cancelComposer()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $settings) { SettingsView(model: model) }
            .task { focused = !processing }
            .onChange(of: model.snapshot.composer.entryID) { old, new in
                if old != nil && new == nil && model.composerText.isEmpty { dismiss() }
            }
        }.font(AppFont.body).presentationDetents([.large]).presentationDragIndicator(.visible)
            .onDisappear { if processing { model.cancelComposer() } }
    }
}

struct ComposerError: View {
    @ObservedObject var model: AppModel
    var settingsAction: (() -> Void)?
    var editAction: (() -> Void)?
    private var needsRecording: Bool {
        if model.recordingFailed { return true }
        guard let id = model.snapshot.composer.entryID, model.issue != nil,
            !model.engine.hasPendingSave(id)
        else { return false }
        return model.snapshot.attempts.last(where: { $0.entryID == id })?.kind == .transcription
    }
    private var message: String? {
        guard !model.composerBusy else { return nil }
        let message = model.composerError ?? model.issue?.message
        if needsRecording && model.issue == .invalidResponse {
            return "Couldn't transcribe your recording. Record again or type your description."
        }
        // Cancellation is an intentional action, not an error.
        return model.issue == .cancelled && model.composerError == nil ? nil : message
    }
    var body: some View {
        if let message {
            ErrorNotice(
                message: message,
                title: model.issue == .nutritionOutOfRange ? "Meal estimate is too large" : nil,
                actionTitle: recoveryTitle, action: recover)
        }
    }
    private var recoveryTitle: String {
        if model.microphoneDenied || model.issue?.opensSettings == true { return "Open Settings" }
        if model.issue == .nutritionOutOfRange { return "Edit description" }
        return needsRecording
            || model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Record again" : "Try again"
    }
    private func recover() {
        if model.issue == .nutritionOutOfRange {
            if let editAction { editAction() } else { model.showTextInput = true }
        } else if model.microphoneDenied {
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        } else if model.issue?.opensSettings == true {
            if let settingsAction { settingsAction() } else { model.showSettings = true }
        } else if needsRecording
            || model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            model.showTextInput = false
            model.toggleMicrophone()
        } else {
            model.submit()
        }
    }
}
