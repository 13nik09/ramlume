import SwiftUI

/// Advanced Details: everything technical, out of the way of the simple pages.
struct AdvancedView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.advancedPage {
        case .memory: MemoryDetailsView()
        case .history: HistoryView()
        case .events: EventsView()
        case .definitions: MetricsGuideView()
        }
    }
}

/// Chooses the Advanced Details page.
struct AdvancedPagePicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Picker("Page", selection: $app.advancedPage) {
            ForEach(AdvancedPage.allCases) { page in
                Text(page.title).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Choose what to see in detail")
    }
}
