import NutritionCore
import SwiftUI

private struct EntrySelection: Identifiable { let id: UUID }

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedEntry: EntrySelection?
    var body: some View {
        NavigationStack {
            List {
                if model.entries.isEmpty {
                    ContentUnavailableView(
                        "No meals yet", systemImage: "clock",
                        description: Text("Meals for this day will appear here.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(model.entries) { entry in
                            Button {
                                selectedEntry = EntrySelection(id: entry.id)
                            } label: {
                                row(entry)
                            }
                            .buttonStyle(.plain).listRowBackground(Color.clear)
                            .transition(
                                reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
                            )
                        }
                    } header: {
                        HStack {
                            Text("kcal").frame(maxWidth: .infinity, alignment: .leading)
                            Text("protein").frame(maxWidth: .infinity)
                            Text("fiber").frame(maxWidth: .infinity, alignment: .trailing)
                        }.font(AppFont.caption).textCase(nil)
                    }
                }
            }
            .task { await model.engine.refresh() }
            .refreshable { await model.engine.refresh() }
            .listStyle(.plain).scrollContentBackground(.hidden).background(Color.appBackground)
            .navigationTitle("Meal history").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
            .sheet(item: $selectedEntry) { selection in
                EntryDetailView(model: model, entryID: selection.id)
            }
            .animation(reduceMotion ? nil : .snappy, value: model.entries.map(\.id))
        }.font(AppFont.body).presentationDetents([.medium, .large]).presentationDragIndicator(
            .visible)
    }
    private func row(_ entry: EntryRecord) -> some View {
        HStack {
            Text(entry.nutrition?.calorieLabel ?? "—").frame(
                maxWidth: .infinity, alignment: .leading)
            Text(entry.nutrition.map { $0.gramLabel($0.protein) + " g" } ?? "—").frame(
                maxWidth: .infinity)
            Text(entry.nutrition.map { $0.gramLabel($0.fiber) + " g" } ?? "—").frame(
                maxWidth: .infinity, alignment: .trailing)
        }.padding(.vertical, 20).contentShape(.rect)
            .accessibilityElement(children: .ignore).accessibilityLabel(rowLabel(entry))
    }
    private func rowLabel(_ entry: EntryRecord) -> String {
        guard let n = entry.nutrition else { return "Unfinished meal. Open to review or retry." }
        return
            "\(n.calorieLabel) calories, \(n.gramLabel(n.protein)) grams protein, \(n.gramLabel(n.fiber)) grams fiber. Edit meal."
    }
}
