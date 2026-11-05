import Testing
@testable import EasyDockCore

@Suite struct LaunchItemsTests {
    @Test func theProgramFromEachKey() {
        let program = LaunchItem(plist: ["Label": "com.example.a", "Program": "/opt/a"], path: "/Library/LaunchDaemons/a.plist", scope: .globalDaemon)
        #expect(program?.programPath == "/opt/a")
        let arguments = LaunchItem(plist: ["Label": "com.example.b", "ProgramArguments": ["/usr/local/bin/b", "--run"]], path: "/x.plist", scope: .userAgent)
        #expect(arguments?.programPath == "/usr/local/bin/b")
        let inApp = LaunchItem(plist: ["Label": "com.example.c", "BundleProgram": "Contents/MacOS/helper", "AssociatedBundleIdentifiers": "com.example.App"],
                               path: "/Applications/Example.app/Contents/Library/LaunchAgents/c.plist", scope: .appAgent)
        #expect(inApp?.programPath == "/Applications/Example.app/Contents/MacOS/helper")
        #expect(inApp?.associatedBundleIDs == ["com.example.App"])
        #expect(LaunchItem(plist: ["Program": "/opt/a"], path: "/x.plist", scope: .userAgent) == nil)
    }

    @Test func labelsSafeForACommand() {
        #expect(LaunchItems.isValidLabel("com.example.agent-2_x"))
        #expect(!LaunchItems.isValidLabel(""))
        #expect(!LaunchItems.isValidLabel("com.example; rm -rf ~"))
        #expect(!LaunchItems.isValidLabel("com.example/agent"))
        #expect(!LaunchItems.isValidLabel("com.exämple"))
    }

    @Test func theAppAProgramIsIn() {
        #expect(LaunchItems.appBundle(containing: "/Applications/Example.app/Contents/MacOS/x") == "/Applications/Example.app")
        #expect(LaunchItems.appBundle(containing: "/Applications/Suite.app/Contents/Helpers/Inner.app/Contents/MacOS/x") == "/Applications/Suite.app")
        #expect(LaunchItems.appBundle(containing: "/Library/PrivilegedHelperTools/com.example.helper") == nil)
    }

    @Test func anAgentWhoseProgramIsGoneIsAnOrphan() {
        let item = LaunchItem(plist: ["Label": "com.example.a", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/agent"]], path: "/x.plist", scope: .userAgent)!
        #expect(LaunchItems.isOrphan(item) { _ in false })
        #expect(!LaunchItems.isOrphan(item) { _ in true })
        let command = LaunchItem(plist: ["Label": "com.example.b", "ProgramArguments": ["sh", "-c", "true"]], path: "/x.plist", scope: .userAgent)!
        #expect(!LaunchItems.isOrphan(command) { _ in false })
    }

    @Test func loadedServicesFromPrint() {
        let output = """
        system = {
        \tservices = {
        \t\t       0      - \tcom.apple.rpmuxd
        \t\t    2988      - \tcom.adobe.acc.installer.v2
        \t\t     554     78 \tcom.cloudflare.warp.daemon
        \t}
        \tother = {
        \t\t    1234      - \tnot.a.service
        \t}
        }
        """
        #expect(LaunchItems.loadedServices(fromPrint: output) == ["com.apple.rpmuxd": 0, "com.adobe.acc.installer.v2": 2988, "com.cloudflare.warp.daemon": 554])
    }

    @Test func disabledServicesFromPrintDisabled() {
        let output = """
        \tdisabled services = {
        \t\t"com.example.on" => enabled
        \t\t"com.example.off" => disabled
        \t\t"com.example.old" => true
        \t}
        \tlogin item associations = {
        \t\t"com.example.x" => disabled
        \t}
        """
        #expect(LaunchItems.disabledServices(fromPrintDisabled: output) == ["com.example.on": false, "com.example.off": true, "com.example.old": true])
    }
}
