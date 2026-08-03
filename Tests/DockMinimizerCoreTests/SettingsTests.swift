import Foundation
import Testing
@testable import DockMinimizerCore

private func makeDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Test("기본값은 활성 상태다")
func defaultsToEnabled() {
    let settings = Settings(defaults: makeDefaults("test.enabled"))
    #expect(settings.isEnabled)
}

@Test("Finder와 자기 자신은 항상 제외된다")
func alwaysExcludesFinderAndSelf() {
    let settings = Settings(defaults: makeDefaults("test.builtin"))
    #expect(settings.excludedBundleIDs.contains("com.apple.finder"))
    #expect(settings.excludedBundleIDs.contains("com.changhun.dockminimizer"))
}

@Test("사용자가 추가한 제외 앱이 목록에 합쳐진다")
func mergesUserExclusions() {
    let settings = Settings(defaults: makeDefaults("test.merge"))
    settings.addExclusion("com.apple.Safari")
    #expect(settings.excludedBundleIDs.contains("com.apple.Safari"))
    #expect(settings.excludedBundleIDs.contains("com.apple.finder"))
}

@Test("사용자 제외 앱을 제거할 수 있다")
func removesUserExclusions() {
    let settings = Settings(defaults: makeDefaults("test.remove"))
    settings.addExclusion("com.apple.Safari")
    settings.removeExclusion("com.apple.Safari")
    #expect(!settings.excludedBundleIDs.contains("com.apple.Safari"))
}

@Test("고정 제외 앱은 제거되지 않는다")
func cannotRemoveBuiltinExclusions() {
    let settings = Settings(defaults: makeDefaults("test.pinned"))
    settings.removeExclusion("com.apple.finder")
    #expect(settings.excludedBundleIDs.contains("com.apple.finder"))
}

@Test("설정이 영속화된다")
func persistsAcrossInstances() {
    let defaults = makeDefaults("test.persist")
    let first = Settings(defaults: defaults)
    first.isEnabled = false
    first.addExclusion("com.apple.Safari")

    let second = Settings(defaults: defaults)
    #expect(!second.isEnabled)
    #expect(second.userExcludedBundleIDs.contains("com.apple.Safari"))
}
