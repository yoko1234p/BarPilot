import Foundation

/// Assessment allowlisting must resolve the same physical, installed app as the running controller.
public enum MenuBarLaunchLocation {
    public static func supportsAssessment(
        running: URL, registered: URL?,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    ) -> Bool {
        guard let registered else { return false }
        let actual = running.standardizedFileURL.resolvingSymlinksInPath()
        let selected = registered.standardizedFileURL.resolvingSymlinksInPath()
        let directory = applicationsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        return actual == selected && actual.path.hasPrefix(directory.path + "/")
    }
}
