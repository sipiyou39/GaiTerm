import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            return nil
        }

        // GaiTerm ships a single appcast from its GitHub Releases (latest
        // release's appcast.xml asset). Both channels point at it.
        _ = appDelegate
        return "https://github.com/sipiyou39/GaiTerm/releases/latest/download/appcast.xml"
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        ))
        return true
    }
}
