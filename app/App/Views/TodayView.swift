import NutritionCore
import SwiftUI

struct TodayView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var calendarPresented = false
    @State private var historyPresented = false
    @State private var dateDraft = Date()

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 32)
                    NutrientView(value: model.totals.calorieLabel, label: "calories", large: true)
                    HStack(spacing: 18) {
                        NutrientView(
                            value: model.totals.gramLabel(model.totals.protein) + " g",
                            label: "protein")
                        Divider().frame(height: 46)
                        NutrientView(
                            value: model.totals.gramLabel(model.totals.fiber) + " g", label: "fiber"
                        )
                    }.padding(.top, 30).padding(.horizontal, 20)
                    Spacer(minLength: 42)
                    actions
                    ComposerError(model: model).padding(
                        .top, model.composerError != nil || model.issue != nil ? 20 : 0)
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24).padding(.top, 12)
                .frame(minHeight: geometry.size.height)
            }
            .refreshable { await model.reconnect() }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color.appBackground)
        }
        .font(AppFont.body)
        .sheet(isPresented: $calendarPresented) { calendar }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $model.showTextInput) { TextInputView(model: model) }
        .sheet(isPresented: $historyPresented) { HistoryView(model: model) }
        .sensoryFeedback(.success, trigger: model.successPulse)
        .sensoryFeedback(.error, trigger: model.errorPulse)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && (model.recording || model.startingRecording) {
                model.cancelComposer()
            }
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            TimelineView(.periodic(from: Calendar.current.startOfDay(for: Date()), by: 60)) {
                context in
                Text(dateLabel(now: context.date))
                    .font(AppFont.body).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true
                    )
                    .accessibilityLabel(
                        model.selectedDate.formatted(date: .complete, time: .omitted))
            }
            Spacer(minLength: 0)
            Button {
                dateDraft = model.selectedDate
                calendarPresented = true
            } label: {
                Image(systemName: "calendar").frame(width: 28, height: 28)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle)
            .disabled(model.composerBusy).accessibilityLabel("Choose date")
            Button {
                model.showSettings = true
            } label: {
                Image(systemName: "gearshape").frame(width: 28, height: 28)
            }.buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("Settings")
        }
    }
    private func dateLabel(now: Date) -> String {
        if let label = MealDay.relativeLabel(for: model.selectedDate, now: now) { return label }
        return model.selectedDate.formatted(
            .dateTime.weekday(.abbreviated).month(.abbreviated).day().year().locale(
                Locale(identifier: "en_US")))
    }
    private var transcribing: Bool {
        model.composerBusy && model.composerEntry?.phase == .transcribing
    }
    private var analyzing: Bool {
        model.composerBusy && !model.recording && !model.startingRecording && !transcribing
    }
    private var actions: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    if transcribing || model.startingRecording {
                        model.cancelComposer()
                    } else {
                        model.toggleMicrophone()
                    }
                } label: {
                    microphoneLabel
                }
                .buttonStyle(.glass).buttonBorderShape(.roundedRectangle(radius: 28))
                .tint(model.recording ? .red : .primary)
                .disabled(analyzing)
                .accessibilityLabel(
                    model.recording
                        ? "Stop recording"
                        : transcribing ? "Cancel transcription" : "Record food description"
                )
                .accessibilityValue(
                    model.recording ? "Recording" : transcribing ? "Transcribing" : "")
                Button {
                    model.showTextInput = true
                } label: {
                    VStack(spacing: 8) {
                        if analyzing {
                            ProgressView().controlSize(.regular)
                        } else {
                            Image(systemName: "keyboard").font(.system(size: 25))
                        }
                        if analyzing { Image(systemName: "arrow.up.right").font(.caption) }
                    }.frame(maxWidth: .infinity).frame(height: 66)
                }.buttonStyle(.glass).buttonBorderShape(.roundedRectangle(radius: 28))
                    .disabled(model.recording || model.startingRecording || transcribing)
                    .accessibilityLabel(
                        analyzing ? "Open meal being analyzed" : "Type food description")
                Button {
                    historyPresented = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 25))
                        .frame(maxWidth: .infinity).frame(height: 66)
                }.buttonStyle(.glass).buttonBorderShape(.roundedRectangle(radius: 28))
                    .accessibilityLabel("Meal history").accessibilityValue(
                        "\(model.entries.count) entries")
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: model.recording)
        .animation(reduceMotion ? nil : .snappy, value: model.composerBusy)
    }
    private var microphoneLabel: some View {
        VStack(spacing: 6) {
            if model.recording {
                HStack(spacing: 7) {
                    Image(systemName: "stop.fill").font(.system(size: 12))
                    AudioWaveform(level: model.audioLevel)
                }.frame(height: 26)
                Text(model.recordingStarted, style: .timer).font(AppFont.caption).monospacedDigit()
            } else if transcribing || model.startingRecording {
                ProgressView().controlSize(.regular)
                HStack(spacing: 6) {
                    if let id = model.snapshot.composer.entryID,
                        let deadline = model.engine.waitingUntil[id]
                    {
                        Text(deadline, style: .timer).font(AppFont.caption).monospacedDigit()
                    }
                    Image(systemName: "xmark").font(.caption)
                }
            } else {
                Image(systemName: "mic").font(.system(size: 25))
            }
        }.frame(maxWidth: .infinity).frame(height: 66)
    }
    private var calendar: some View {
        NavigationStack {
            DatePicker(
                "Consumption date", selection: $dateDraft, in: ...Date(), displayedComponents: .date
            )
            .datePickerStyle(.graphical).padding()
            .navigationTitle("Choose date").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.selectedDate = dateDraft
                        calendarPresented = false
                    }
                }
            }
        }.presentationDetents([.medium, .large])
    }
}

private struct AudioWaveform: View {
    var level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { index in
                Capsule().frame(width: 3, height: 4 + level * Double([12, 20, 26, 17, 10][index]))
            }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level).accessibilityHidden(
            true)
    }
}
