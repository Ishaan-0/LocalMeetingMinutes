import Foundation
import Combine

enum AppPhase {
    case setup
    case home
    case recording
    case summary
}

@MainActor
final class AppState: ObservableObject {
    @Published var phase: AppPhase = .setup
}
