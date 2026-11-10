import Foundation
import LPModel
import Testing
@testable import LockPlus

/// Launch selection (UI-CONCEPT §6.3): with profiles and no selection the main window selects the active profile,
/// else the last used, else the first, and never shows the empty-library view beside a populated sidebar.
@MainActor @Suite("Launch selection", .serialized)
struct LaunchSelectionTests {
    private func model(selection: UUID? = nil) -> ProfilesUIModel {
        ProfilesUIModel(profiles: PreviewData.profiles, selection: selection)
    }

    // MARK: SidebarItem.resolved (what the window reads)

    @Test func nilWithProfilesResolvesToTheBinderSelection() {
        let m = model(selection: PreviewData.globexID)
        #expect(SidebarItem.resolved(nil, in: m) == .profile(PreviewData.globexID))
    }

    @Test func nilWithProfilesAndNoBinderSelectionResolvesToTheFirst() {
        #expect(SidebarItem.resolved(nil, in: model()) == .profile(PreviewData.profiles[0].id))
    }

    @Test func aMissingProfileFallsBackLikeLaunch() {
        let gone = UUID()
        #expect(SidebarItem.resolved(.profile(gone), in: model(selection: PreviewData.globexID)) == .profile(PreviewData.globexID))
        #expect(SidebarItem.resolved(.profile(gone), in: model(selection: UUID())) == .profile(PreviewData.profiles[0].id))
    }

    @Test func anExistingProfileAndTheSectionsStay() {
        let m = model(selection: PreviewData.globexID)
        #expect(SidebarItem.resolved(.profile(PreviewData.workID), in: m) == .profile(PreviewData.workID))
        for s in [SidebarItem.activity, .autoConnect, .diagnostics, .logs] { #expect(SidebarItem.resolved(s, in: m) == s) }
    }

    @Test func anEmptyLibraryResolvesToNothing() {
        let m = ProfilesUIModel(profiles: [], selection: nil)
        #expect(SidebarItem.resolved(nil, in: m) == nil)
        #expect(SidebarItem.resolved(.profile(UUID()), in: m) == nil)
    }

    // MARK: Binder (what sets the selection at launch)

    @Test func theBinderSelectsTheLastUsedProfileAtLaunch() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf)
        let second = try await h.add("Nas.conf", Harness.splitConf)
        h.env.settings.update { $0.lastUsedProfileID = second.id }
        h.env.ui.profiles.selection = nil
        h.env.connection.start()
        UIBinder.render(h.env)
        #expect(h.env.ui.profiles.selection == second.id)
        #expect(SidebarItem.resolved(nil, in: h.env.ui.profiles) == .profile(second.id))
    }

    @Test func theBinderFallsBackToTheFirstWithoutAnActiveOrLastUsedProfile() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf)
        _ = try await h.add("Nas.conf", Harness.splitConf)
        h.env.settings.update { $0.lastUsedProfileID = nil }
        h.env.ui.profiles.selection = nil
        h.env.connection.start()
        UIBinder.render(h.env)
        let selected = try #require(h.env.ui.profiles.selection)
        #expect(selected == h.env.profiles.ordered.first?.id)
        #expect(SidebarItem.resolved(nil, in: h.env.ui.profiles) == .profile(selected))
    }

    @Test func aDeletedSelectionIsRepickedByTheBinder() async throws {
        let h = Harness()
        defer { h.dir.cleanup() }
        _ = try await h.add("Work.conf", Harness.wgConf)
        _ = try await h.add("Nas.conf", Harness.splitConf)
        h.env.connection.start()
        h.env.ui.profiles.selection = UUID()                      // a profile that no longer exists
        UIBinder.render(h.env)
        let selected = try #require(h.env.ui.profiles.selection)
        #expect(h.env.ui.profiles.profile(selected) != nil)
    }
}
