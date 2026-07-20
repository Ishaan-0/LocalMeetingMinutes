import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Text("MeetingMinutes")
            .frame(width: 400, height: 560)
    }
}
