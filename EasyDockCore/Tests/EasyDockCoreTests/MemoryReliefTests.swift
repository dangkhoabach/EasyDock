import Foundation
import Testing
@testable import EasyDockCore

@Suite struct MemoryReliefTests {
    private let gb: UInt64 = 1_000_000_000

    @Test func theHeaviestAppsNotInUse() {
        let apps = [
            AppMemory(bundleID: "com.example.editor", name: "Editor", bytes: 6 * gb),
            AppMemory(bundleID: "com.example.browser", name: "Browser", bytes: 3 * gb),
            AppMemory(bundleID: "com.apple.finder", name: "Finder", bytes: 2 * gb),
            AppMemory(bundleID: "com.example.chat", name: "Chat", bytes: gb),
            AppMemory(bundleID: "com.example.notes", name: "Notes", bytes: 200_000_000),
            AppMemory(bundleID: "com.example.music", name: "Music", bytes: 500_000_000),
        ]
        let picked = MemoryRelief.suggestions(apps, frontmost: "com.example.browser").map(\.name)
        #expect(picked == ["Editor", "Chat", "Music"])
    }
}

@Suite struct IdleQuitTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let rules = ["com.example.xcode": 60, "com.example.slack": 30]

    @Test func dueOnceUnusedForItsMinutes() {
        let lastUsed = ["com.example.xcode": now.addingTimeInterval(-61 * 60), "com.example.slack": now.addingTimeInterval(-10 * 60)]
        let running: Set = ["com.example.xcode", "com.example.slack"]
        #expect(IdleQuit.due(rules: rules, lastUsed: lastUsed, running: running, frontmost: nil, asked: [], now: now) == ["com.example.xcode"])
        // The next one: Slack, twenty minutes from now.
        #expect(IdleQuit.nextDeadline(rules: rules, lastUsed: lastUsed, running: running, frontmost: nil, asked: ["com.example.xcode"])
                == now.addingTimeInterval(20 * 60))
    }

    /// In front, not open, or already asked: never.
    @Test func neverTheAppInFrontOrOneAlreadyAsked() {
        let lastUsed = ["com.example.xcode": now.addingTimeInterval(-2 * 3600)]
        #expect(IdleQuit.due(rules: rules, lastUsed: lastUsed, running: ["com.example.xcode"], frontmost: "com.example.xcode", asked: [], now: now).isEmpty)
        #expect(IdleQuit.due(rules: rules, lastUsed: lastUsed, running: [], frontmost: nil, asked: [], now: now).isEmpty)
        #expect(IdleQuit.due(rules: rules, lastUsed: lastUsed, running: ["com.example.xcode"], frontmost: nil, asked: ["com.example.xcode"], now: now).isEmpty)
        #expect(IdleQuit.nextDeadline(rules: rules, lastUsed: lastUsed, running: ["com.example.xcode"], frontmost: "com.example.xcode", asked: []) == nil)
    }

    @Test func rulesRoundTrip() {
        let text = IdleQuit.encode(rules)
        #expect(text == "com.example.slack=30\ncom.example.xcode=60")
        #expect(IdleQuit.decode(text) == rules)
        #expect(IdleQuit.decode("broken\ncom.example.a=0\ncom.example.b=15") == ["com.example.b": 15])
    }
}
