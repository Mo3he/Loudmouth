import SwiftUI

// MARK: - ContentView
/// Root view. Tab bar on iPhone; NavigationSplitView on iPad and Mac.
struct ContentView: View {
    @EnvironmentObject var player: PlayerViewModel
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var sources: SourceViewModel
    @StateObject var search = SearchViewModel()

    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("accentColorHex") private var accentColorHex = "00D9E6"
    @State private var columnVisibility: NavigationSplitViewVisibility =
        CommandLine.arguments.contains("--demo-mode") ? .all : .automatic
    @State private var iPadSection: iPadSidebarSection = .library
    @State private var iPadSectionSet: Set<iPadSidebarSection> = [.library]

    private enum iPadSidebarSection: String, Hashable, CaseIterable {
        case library, vibe, sources, settings

        var title: String {
            switch self {
            case .library: return "Library"
            case .vibe:    return "Vibe"
            case .sources: return "Sources"
            case .settings: return "Settings"
            }
        }

        var icon: String {
            switch self {
            case .library:  return "music.note.list"
            case .vibe:     return "waveform.circle.fill"
            case .sources:  return "externaldrive"
            case .settings: return "gearshape"
            }
        }
    }

    private var accentColor: Color { Color(hex: accentColorHex) ?? .kCyan }

    private var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                iPadLayout
            } else {
                iPhoneLayout
            }
            #else
            macLayout
            #endif
        }
        .environment(\..kAccent, accentColor)
        .preferredColorScheme(preferredScheme)
        .sheet(isPresented: $player.showingNowPlaying) {
            NowPlayingView()
                .environmentObject(player)
                .environment(\.colorScheme, .dark)
                .environment(\.kAccent, accentColor)
        }
        .onAppear {
            // Wire SourceViewModel → LibraryViewModel for post-upload scans
            sources.libraryViewModel = library
        }
    }

    // MARK: - iPhone tab bar
    private var iPhoneLayout: some View {
        TabView {
            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "music.note.list") }

            VibeView()
                .tabItem { Label("Vibe", systemImage: "waveform.circle.fill") }

            SourcesView()
                .tabItem { Label("Sources", systemImage: "externaldrive") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.state.status != .stopped {
                Color.clear.frame(height: 66)
            }
        }
        .overlay(alignment: .bottom) {
            MiniPlayerView()
                .environmentObject(player)
                .environment(\.colorScheme, .dark)
                .padding(.bottom, 57)   // above tab bar with 8pt gap
        }
        .tint(accentColor)
    }

    // MARK: - iPad split
    private var iPadLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(iPadSidebarSection.allCases, id: \.self, selection: $iPadSectionSet) { section in
                Label(section.title, systemImage: section.icon)
            }
            .navigationTitle("Kenopsia")
        } detail: {
            iPadDetailView
        }
        .environment(\.sidebarToggle, {
            withAnimation { columnVisibility = columnVisibility == .all ? .detailOnly : .all }
        })
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.state.status != .stopped {
                Color.clear.frame(height: 78)
            }
        }
        .overlay(alignment: .bottom) {
            MiniPlayerView()
                .environmentObject(player)
                .environment(\.colorScheme, .dark)
                .environment(\.kAccent, accentColor)
                .padding(.bottom, 20)
        }
        .tint(accentColor)
    }

    @ViewBuilder
    private var iPadDetailView: some View {
        switch iPadSectionSet.first ?? .library {
        case .library:
            NavigationStack { LibraryView() }
        case .vibe:
            VibeView()
        case .sources:
            SourcesView()
        case .settings:
            SettingsView()
        }
    }

    // MARK: - Mac (Catalyst)
    private var macLayout: some View {
        iPadLayout
    }
}
