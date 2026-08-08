import Foundation
import TesseraCore
#if canImport(AppKit)
import AppKit
#endif

#if canImport(AppKit)

@MainActor
final class PleadTheFifthComposition {
    static let shared = PleadTheFifthComposition()

    private var menuItem: PleadTheFifthMenuItem?
    private var hotKeyMonitor: HotKeyMonitor?
    private var executor: PleadTheFifthExecutor?

    private init() {}

    func install() {
        let config = TesseraAppLifecycle.defaultVolumeConfig()
        let volume = TesseraEncryptedVolume(config: config)
        let exec = PleadTheFifthExecutor(volume: volume)
        self.executor = exec

        Task {
            await CovertTriggerMonitor.shared.loadFromKeychain()
            await CovertTriggerMonitor.shared.setOnFire { [weak exec] in
                guard let exec else { return }
                _ = try? await exec.destroyAll(trigger: .covert)
            }
        }

        menuItem = PleadTheFifthMenuItem(volume: volume)

        hotKeyMonitor = HotKeyMonitor(chord: .defaultChord) { [weak exec] in
            guard let exec else { return }
            Task { _ = try? await exec.destroyAll(trigger: .hotkey) }
        }
        _ = hotKeyMonitor?.start()
    }

    func uninstall() {
        hotKeyMonitor?.stop()
        hotKeyMonitor = nil
        menuItem?.uninstall()
        menuItem = nil
        Task {
            await CovertTriggerMonitor.shared.setOnFire(nil)
        }
        executor = nil
    }
}

#else

@MainActor
final class PleadTheFifthComposition {
    static let shared = PleadTheFifthComposition()
    private init() {}
    func install() {
        Task { await CovertTriggerMonitor.shared.loadFromKeychain() }
    }
    func uninstall() {}
}

#endif
