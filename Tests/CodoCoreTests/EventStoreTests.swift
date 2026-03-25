import Foundation
import Testing

@testable import CodoCore

// MARK: - Helper

private func makeStore() throws -> EventStore {
    try EventStore(path: ":memory:")
}

// MARK: - Schema & Init

@Suite("EventStore — Init & Schema")
struct EventStoreInitTests {
    @Test func inMemoryCreation() throws {
        let store = try makeStore()
        // Should not throw — schema created successfully
        store.close()
    }

    @Test func doubleCloseDoesNotCrash() throws {
        let store = try makeStore()
        store.close()
        store.close()  // Second close should be a no-op
    }
}

// MARK: - Event CRUD

@Suite("EventStore — Event CRUD")
struct EventStoreEventTests {
    @Test func insertAndQueryEvent() throws {
        let store = try makeStore()
        defer { store.close() }

        let event = EventRecord(
            type: "hook",
            hookType: "session-start",
            sessionId: "s1",
            projectCwd: "/tmp/project-a",
            projectName: "project-a",
            summary: "Session started (claude-sonnet)"
        )
        store.insertEvent(event)

        let results = store.queryEvents()
        #expect(results.count == 1)
        #expect(results[0].type == "hook")
        #expect(results[0].hookType == "session-start")
        #expect(results[0].sessionId == "s1")
        #expect(results[0].summary == "Session started (claude-sonnet)")
    }

    @Test func queryEventsFilterByProject() throws {
        let store = try makeStore()
        defer { store.close() }

        store.insertEvent(EventRecord(type: "hook", projectCwd: "/tmp/a", summary: "event-a"))
        store.insertEvent(EventRecord(type: "hook", projectCwd: "/tmp/b", summary: "event-b"))
        store.insertEvent(EventRecord(type: "hook", projectCwd: "/tmp/a", summary: "event-a2"))

        let resultsA = store.queryEvents(project: "/tmp/a")
        #expect(resultsA.count == 2)
        #expect(resultsA.allSatisfy { $0.projectCwd == "/tmp/a" })

        let resultsB = store.queryEvents(project: "/tmp/b")
        #expect(resultsB.count == 1)
        #expect(resultsB[0].summary == "event-b")
    }

    @Test func queryEventsFilterByType() throws {
        let store = try makeStore()
        defer { store.close() }

        store.insertEvent(EventRecord(type: "hook", summary: "hook-event"))
        store.insertEvent(EventRecord(type: "notification", summary: "notif-event"))
        store.insertEvent(EventRecord(type: "hook", summary: "hook-event-2"))

        let hooks = store.queryEvents(type: "hook")
        #expect(hooks.count == 2)

        let notifs = store.queryEvents(type: "notification")
        #expect(notifs.count == 1)
    }

    @Test func queryEventsFilterBySince() throws {
        let store = try makeStore()
        defer { store.close() }

        let old = Date(timeIntervalSince1970: 1_000_000)
        let recent = Date()

        store.insertEvent(EventRecord(timestamp: old, type: "hook", summary: "old-event"))
        store.insertEvent(EventRecord(timestamp: recent, type: "hook", summary: "new-event"))

        let since = Date(timeIntervalSinceNow: -60)  // Last 60 seconds
        let results = store.queryEvents(since: since)
        #expect(results.count == 1)
        #expect(results[0].summary == "new-event")
    }

    @Test func queryEventsLimit() throws {
        let store = try makeStore()
        defer { store.close() }

        for i in 0..<10 {
            store.insertEvent(EventRecord(type: "hook", summary: "event-\(i)"))
        }

        let limited = store.queryEvents(limit: 3)
        #expect(limited.count == 3)
    }

    @Test func queryEventsNewestFirst() throws {
        let store = try makeStore()
        defer { store.close() }

        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)
        let t3 = Date(timeIntervalSince1970: 300)

        store.insertEvent(EventRecord(timestamp: t1, type: "hook", summary: "first"))
        store.insertEvent(EventRecord(timestamp: t2, type: "hook", summary: "second"))
        store.insertEvent(EventRecord(timestamp: t3, type: "hook", summary: "third"))

        let results = store.queryEvents()
        #expect(results.count == 3)
        #expect(results[0].summary == "third")
        #expect(results[1].summary == "second")
        #expect(results[2].summary == "first")
    }

    @Test func insertEventWithNullProjectCwd() throws {
        let store = try makeStore()
        defer { store.close() }

        store.insertEvent(EventRecord(type: "notification", projectCwd: nil, summary: "direct notif"))

        let results = store.queryEvents()
        #expect(results.count == 1)
        #expect(results[0].projectCwd == nil)
    }

    @Test func insertEventWithRawJson() throws {
        let store = try makeStore()
        defer { store.close() }

        let raw = #"{"_hook":"stop","session_id":"s1"}"#
        store.insertEvent(EventRecord(type: "hook", summary: "stop event", rawJson: raw))

        let results = store.queryEvents()
        #expect(results.count == 1)
        #expect(results[0].rawJson == raw)
    }
}

// MARK: - Decision CRUD

@Suite("EventStore — Decision CRUD")
struct EventStoreDecisionTests {
    @Test func insertAndQueryDecision() throws {
        let store = try makeStore()
        defer { store.close() }

        let decision = DecisionRecord(
            sessionId: "s1",
            projectCwd: "/tmp/project",
            hookType: "stop",
            tier: "important",
            action: "send",
            title: "Task Complete",
            model: "claude-sonnet",
            promptTokens: 500,
            completionTokens: 100,
            latencyMs: 1200
        )
        store.insertDecision(decision)

        let results = store.queryDecisions()
        #expect(results.count == 1)
        #expect(results[0].action == "send")
        #expect(results[0].title == "Task Complete")
        #expect(results[0].promptTokens == 500)
        #expect(results[0].completionTokens == 100)
        #expect(results[0].latencyMs == 1200)
    }

    @Test func queryDecisionsFilterByProject() throws {
        let store = try makeStore()
        defer { store.close() }

        store.insertDecision(DecisionRecord(projectCwd: "/tmp/a", action: "send", title: "A"))
        store.insertDecision(DecisionRecord(projectCwd: "/tmp/b", action: "suppress", reason: "noise"))
        store.insertDecision(DecisionRecord(projectCwd: "/tmp/a", action: "suppress", reason: "dup"))

        let resultsA = store.queryDecisions(project: "/tmp/a")
        #expect(resultsA.count == 2)

        let resultsB = store.queryDecisions(project: "/tmp/b")
        #expect(resultsB.count == 1)
        #expect(resultsB[0].reason == "noise")
    }

    @Test func decisionWithNullTokens() throws {
        let store = try makeStore()
        defer { store.close() }

        store.insertDecision(DecisionRecord(action: "suppress", reason: "fallback"))

        let results = store.queryDecisions()
        #expect(results.count == 1)
        #expect(results[0].promptTokens == nil)
        #expect(results[0].completionTokens == nil)
        #expect(results[0].latencyMs == nil)
    }
}

// MARK: - Daily Stats

@Suite("EventStore — Daily Stats")
struct EventStoreDailyStatsTests {
    @Test func decisionUpdatesDailyStats() throws {
        let store = try makeStore()
        defer { store.close() }

        store.insertDecision(DecisionRecord(
            projectCwd: "/tmp/proj",
            action: "send",
            promptTokens: 100,
            completionTokens: 50
        ))
        store.insertDecision(DecisionRecord(
            projectCwd: "/tmp/proj",
            action: "suppress",
            promptTokens: 80,
            completionTokens: 20
        ))

        let stats = store.dailyStats(project: "/tmp/proj")
        #expect(stats.count == 1)
        #expect(stats[0].eventsCount == 2)
        #expect(stats[0].sentCount == 1)
        #expect(stats[0].suppressedCount == 1)
        #expect(stats[0].promptTokens == 180)
        #expect(stats[0].completionTokens == 70)
        #expect(stats[0].llmCalls == 2)
    }

    @Test func unattributedDecisionGoesToSentinel() throws {
        let store = try makeStore()
        defer { store.close() }

        store.insertDecision(DecisionRecord(projectCwd: nil, action: "send"))

        let stats = store.dailyStats()
        #expect(stats.count == 1)
        #expect(stats[0].projectCwd == DailyStatsRecord.unattributed)
    }

    @Test func dailyStatsFilterByProject() throws {
        let store = try makeStore()
        defer { store.close() }

        store.insertDecision(DecisionRecord(projectCwd: "/tmp/a", action: "send"))
        store.insertDecision(DecisionRecord(projectCwd: "/tmp/b", action: "send"))

        let statsA = store.dailyStats(project: "/tmp/a")
        #expect(statsA.count == 1)
        #expect(statsA[0].sentCount == 1)

        let statsAll = store.dailyStats()
        #expect(statsAll.count == 2)
    }
}

// MARK: - Projects

@Suite("EventStore — Projects")
struct EventStoreProjectTests {
    @Test func upsertAndLoadProject() throws {
        let store = try makeStore()
        defer { store.close() }

        let project = ProjectRecord(
            cwd: "/tmp/my-project",
            name: "my-project",
            lastSeen: Date()
        )
        store.upsertProject(project)

        let loaded = store.loadProjects()
        #expect(loaded.count == 1)
        #expect(loaded[0].cwd == "/tmp/my-project")
        #expect(loaded[0].name == "my-project")
        #expect(loaded[0].customLogoPath == nil)
    }

    @Test func upsertUpdatesExistingProject() throws {
        let store = try makeStore()
        defer { store.close() }

        let p1 = ProjectRecord(cwd: "/tmp/proj", name: "proj", lastSeen: Date(timeIntervalSince1970: 100))
        store.upsertProject(p1)

        let p2 = ProjectRecord(cwd: "/tmp/proj", name: "proj-renamed", customLogoPath: "/logo.png", lastSeen: Date())
        store.upsertProject(p2)

        let loaded = store.loadProjects()
        #expect(loaded.count == 1)
        #expect(loaded[0].name == "proj-renamed")
        #expect(loaded[0].customLogoPath == "/logo.png")
    }

    @Test func loadProjectsNewestFirst() throws {
        let store = try makeStore()
        defer { store.close() }

        store.upsertProject(ProjectRecord(cwd: "/tmp/old", name: "old", lastSeen: Date(timeIntervalSince1970: 100)))
        store.upsertProject(ProjectRecord(cwd: "/tmp/new", name: "new", lastSeen: Date()))

        let loaded = store.loadProjects()
        #expect(loaded.count == 2)
        #expect(loaded[0].cwd == "/tmp/new")
        #expect(loaded[1].cwd == "/tmp/old")
    }
}

// MARK: - Vacuum

@Suite("EventStore — Vacuum")
struct EventStoreVacuumTests {
    @Test func vacuumRemovesOldData() throws {
        let store = try makeStore()
        defer { store.close() }

        let old = Date(timeIntervalSince1970: 1_000_000)  // ~1970-01-12
        let recent = Date()

        store.insertEvent(EventRecord(timestamp: old, type: "hook", summary: "ancient"))
        store.insertEvent(EventRecord(timestamp: recent, type: "hook", summary: "fresh"))

        store.insertDecision(DecisionRecord(timestamp: old, action: "send"))
        store.insertDecision(DecisionRecord(timestamp: recent, action: "suppress"))

        // Vacuum with 30-day retention
        store.vacuum(keepDays: 30)

        let events = store.queryEvents()
        #expect(events.count == 1)
        #expect(events[0].summary == "fresh")

        let decisions = store.queryDecisions()
        #expect(decisions.count == 1)
        #expect(decisions[0].action == "suppress")
    }

    @Test func vacuumKeepsRecentData() throws {
        let store = try makeStore()
        defer { store.close() }

        store.insertEvent(EventRecord(type: "hook", summary: "today"))
        store.vacuum(keepDays: 1)

        let events = store.queryEvents()
        #expect(events.count == 1)
    }
}

// MARK: - Concurrent Safety

@Suite("EventStore — Concurrency")
struct EventStoreConcurrencyTests {
    @Test func concurrentInsertAndQuery() throws {
        let store = try makeStore()
        defer { store.close() }

        let group = DispatchGroup()
        let insertQueue = DispatchQueue(label: "test.insert", attributes: .concurrent)
        let queryQueue = DispatchQueue(label: "test.query", attributes: .concurrent)

        // Concurrent inserts
        for i in 0..<50 {
            group.enter()
            insertQueue.async {
                store.insertEvent(EventRecord(
                    type: "hook",
                    projectCwd: "/tmp/proj",
                    summary: "event-\(i)"
                ))
                group.leave()
            }
        }

        // Concurrent queries during inserts
        for _ in 0..<20 {
            group.enter()
            queryQueue.async {
                _ = store.queryEvents()
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 10)
        #expect(result == .success)

        // All 50 events should be present
        let allEvents = store.queryEvents(limit: 100)
        #expect(allEvents.count == 50)
    }
}

// MARK: - Combined Filters

@Suite("EventStore — Combined Filters")
struct EventStoreCombinedFilterTests {
    @Test func queryEventsWithMultipleFilters() throws {
        let store = try makeStore()
        defer { store.close() }

        store.insertEvent(EventRecord(type: "hook", hookType: "stop", projectCwd: "/tmp/a", summary: "hook-a"))
        store.insertEvent(EventRecord(type: "notification", projectCwd: "/tmp/a", summary: "notif-a"))
        store.insertEvent(EventRecord(type: "hook", hookType: "stop", projectCwd: "/tmp/b", summary: "hook-b"))

        // Filter by project AND type
        let results = store.queryEvents(project: "/tmp/a", type: "hook")
        #expect(results.count == 1)
        #expect(results[0].summary == "hook-a")
    }

    @Test func emptyResultsOnNoMatch() throws {
        let store = try makeStore()
        defer { store.close() }

        store.insertEvent(EventRecord(type: "hook", projectCwd: "/tmp/a", summary: "event"))

        let results = store.queryEvents(project: "/tmp/nonexistent")
        #expect(results.isEmpty)
    }
}
