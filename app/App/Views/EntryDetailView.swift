import NutritionCore
import SwiftUI

struct EntryDetailView: View {
    @ObservedObject var model: AppModel
    let entryID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var input = ""
    @State private var loaded = false
    @State private var confirmClose = false
    @State private var confirmDelete = false
    @State private var settings = false
    @State private var localError: TrackerError?
    @FocusState private var inputFocused: Bool
    private var entry: EntryRecord? { model.entry(entryID) }
    private var busy: Bool { model.engine.isBusy(entryID) }
    private var dirty: Bool { input != entry?.originalInput }
    private var issue: TrackerError? { localError ?? model.engine.issues[entryID] }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Edit entry").font(
                        .custom("Huninn-Regular", size: 34, relativeTo: .largeTitle))
                    if let entry {
                        Text(entryDate(entry)).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            NutrientView(value: entry.nutrition?.calorieLabel ?? "—", label: "kcal")
                            Divider().frame(height: 54)
                            NutrientView(
                                value: entry.nutrition.map { $0.gramLabel($0.protein) + " g" }
                                    ?? "—",
                                label: "protein")
                            Divider().frame(height: 54)
                            NutrientView(
                                value: entry.nutrition.map { $0.gramLabel($0.fiber) + " g" } ?? "—",
                                label: "fiber")
                        }.padding(.vertical, 12)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your input").foregroundStyle(.secondary)
                        TextEditor(text: $input).frame(minHeight: 140).scrollContentBackground(
                            .hidden
                        )
                        .focused($inputFocused)
                        .padding(12).background(.quaternary, in: .rect(cornerRadius: 20))
                        .disabled(busy).accessibilityLabel("Original food description")
                    }
                    if !inputFocused { reanalyzeButton }
                    if busy {
                        ProcessingStatus(
                            label: entry?.phase == .saving ? "Saving" : "Analyzing",
                            waitingUntil: model.engine.waitingUntil[entryID]
                        ) { model.engine.cancel(entryID) }
                    } else if let issue, issue != .cancelled {
                        ErrorNotice(
                            message: issue.message,
                            title: issue == .nutritionOutOfRange
                                ? "Meal estimate is too large" : nil,
                            actionTitle: recoveryTitle, action: recover)
                    }
                }.padding(24)
            }
            .background(Color.appBackground)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Group {
                    if inputFocused {
                        reanalyzeButton
                    } else {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete entry", systemImage: "trash").frame(maxWidth: .infinity)
                                .padding(
                                    .vertical, 10)
                        }.buttonStyle(.glass).buttonBorderShape(.capsule).tint(.red)
                            .popover(
                                isPresented: $confirmDelete, attachmentAnchor: .rect(.bounds),
                                arrowEdge: .bottom
                            ) {
                                deleteConfirmation
                            }
                    }
                }.padding(24).background(Color.appBackground)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") { requestClose() }
                }
            }
            .confirmationDialog(
                "Discard unsaved changes?", isPresented: $confirmClose, titleVisibility: .visible
            ) {
                Button("Discard changes", role: .destructive) { close(discard: true) }
                Button("Keep editing", role: .cancel) {}
            }
            .sheet(isPresented: $settings) { SettingsView(model: model) }
            .interactiveDismissDisabled(dirty || busy)
            .onDisappear { model.engine.cancel(entryID) }
            .onAppear {
                if !loaded {
                    input = entry?.draftInput ?? entry?.originalInput ?? ""
                    loaded = true
                }
            }
            .onChange(of: input) { _, text in
                guard loaded, !busy else { return }
                do {
                    try model.engine.updateDraft(entryID: entryID, text: text)
                    localError = nil
                } catch { localError = .persistence }
            }
            .onChange(of: entry?.originalInput) { _, text in
                if let text, entry?.draftInput == nil { input = text }
            }
            .onChange(of: entry == nil) { _, deleted in if deleted { dismiss() } }
            .animation(reduceMotion ? nil : .snappy, value: busy)
        }
        .font(AppFont.body).presentationDragIndicator(.visible).presentationDetents([.large])
    }
    private var reanalyzeButton: some View {
        Button {
            inputFocused = false
            localError = nil
            do { try model.reanalyze(entryID, input: input) } catch {
                localError = TrackerError.normalize(error)
            }
        } label: {
            Label("Reanalyze", systemImage: "sparkles").frame(maxWidth: .infinity).padding(
                .vertical, 10)
        }.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Delete this entry?").font(AppFont.title)
            Text("This cannot be undone.").foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("Cancel") { confirmDelete = false }.buttonStyle(.glass)
                Spacer(minLength: 0)
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await model.engine.delete(entryID)
                            model.successPulse += 1
                            confirmDelete = false
                            dismiss()
                        } catch {
                            confirmDelete = false
                            localError = TrackerError.normalize(error)
                        }
                    }
                }.buttonStyle(.glassProminent).tint(.red)
            }
        }.font(AppFont.body).padding(24).frame(idealWidth: 320)
            .presentationCompactAdaptation(.popover)
    }
    private var recoveryTitle: String? {
        if issue?.opensSettings == true { return "Open Settings" }
        if issue == .nutritionOutOfRange { return "Edit description" }
        if model.engine.hasPendingSave(entryID) { return "Try saving again" }
        // Reanalyze already provides the retry action for analysis and network failures.
        return nil
    }
    private func recover() {
        if issue?.opensSettings == true {
            settings = true
            return
        }
        if issue == .nutritionOutOfRange {
            inputFocused = true
            return
        }
        do {
            if model.engine.hasPendingSave(entryID) {
                try model.engine.retrySaving(entryID)
            } else {
                try model.reanalyze(entryID, input: input)
            }
            localError = nil
        } catch { localError = TrackerError.normalize(error) }
    }
    private func requestClose() { if dirty { confirmClose = true } else { close(discard: false) } }
    private func close(discard: Bool) {
        do {
            if discard {
                try model.engine.discardDraft(entryID: entryID)
            } else {
                model.engine.cancel(entryID)
            }
            dismiss()
        } catch { localError = .persistence }
    }
    private func entryDate(_ entry: EntryRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(identifier: entry.day.timeZoneID)
        formatter.dateFormat = "d MMM yyyy"
        let parts = entry.day.key.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        guard parts.count == 3,
            let date = calendar.date(
                from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return entry.day.key }
        return formatter.string(from: date)
    }
}
