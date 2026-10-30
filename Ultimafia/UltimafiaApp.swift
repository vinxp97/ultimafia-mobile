import SwiftUI

@main
struct UltimafiaApp: App {
    @State private var appModel = AppModel()
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(UMAppDelegate.self) private var appDelegate
    #endif

    init() {
        UMDiag.log("app", "launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        UMDiag.startWatchdog()
        UMCrashReporter.shared.start()
        UMActLayout.migrate()
        #if os(macOS) && !targetEnvironment(macCatalyst) && DEBUG
        let model = _appModel.wrappedValue
        UMMacNativeSnapshot.scheduleIfRequested {
            AnyView(ContentView().environment(model).tint(UMTheme.blood).frame(minWidth: 1100, minHeight: 720))
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .tint(UMTheme.blood)
                .task { UMNameFonts.shared.loadIfNeeded() }
                #if targetEnvironment(macCatalyst)
                .background(UMMacWindowConfigurator().frame(width: 0, height: 0))
                #elseif os(macOS)
                .frame(minWidth: 1100, minHeight: 720)
                #endif
        }
        #if targetEnvironment(macCatalyst)
        .commands { UMMacCommands(app: appModel) }
        #elseif os(macOS)
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands { UMMacNativeCommands(app: appModel) }
        #endif
        #if os(macOS)
        Settings {
            UMMacSettingsScene()
                .environment(appModel)
                .tint(UMTheme.blood)
        }
        #endif
    }
}
