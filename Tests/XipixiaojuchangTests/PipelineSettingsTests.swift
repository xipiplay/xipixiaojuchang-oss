import XCTest
@testable import Xipixiaojuchang

@MainActor
final class PipelineSettingsTests: XCTestCase {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "PipelineSettingsTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    func testSampleConfigurationLoadsWithoutWritingEitherStore() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("sample.plist")
        let config = PipelineAISettings(baseURL: "https://example.invalid/v1", apiKey: "test-only-key", model: "deepseek-flash")
        let data = try PropertyListSerialization.data(fromPropertyList: ["aiConfig": JSONEncoder().encode(config)], format: .binary, options: 0)
        try data.write(to: file)
        let loaded = PipelineAISettingsStore.load(defaults: defaults, sampleURL: file)
        XCTAssertEqual(loaded.config, config)
        XCTAssertTrue(loaded.inherited)
        XCTAssertNil(defaults.data(forKey: PipelineAISettingsStore.defaultsKey))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testSavedConfigurationTakesPriorityAndOnlyNewKeyChanges() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let channels = Data("original-channels".utf8)
        defaults.set(channels, forKey: "modelChannels")
        defaults.set("existing-model", forKey: "defaultVideoModel")
        let config = PipelineAISettings(baseURL: " https://example.invalid/v1/ ", apiKey: " test-only-key ", model: " custom-model ")
        let saved = try PipelineAISettingsStore.save(config, defaults: defaults)
        XCTAssertEqual(saved.baseURL, "https://example.invalid/v1/")
        XCTAssertEqual(saved.model, "custom-model")
        XCTAssertEqual(PipelineAISettingsStore.load(defaults: defaults, sampleURL: nil).config, saved)
        XCTAssertFalse(PipelineAISettingsStore.load(defaults: defaults, sampleURL: nil).inherited)
        XCTAssertEqual(defaults.data(forKey: "modelChannels"), channels)
        XCTAssertEqual(defaults.string(forKey: "defaultVideoModel"), "existing-model")
    }

    func testInvalidConfigurationCannotOverwriteSavedConfig() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let valid = PipelineAISettings(baseURL: "https://example.invalid", apiKey: "test-only-key", model: "deepseek-flash")
        try PipelineAISettingsStore.save(valid, defaults: defaults)
        let before = defaults.data(forKey: PipelineAISettingsStore.defaultsKey)
        for address in ["missing-scheme", "file:///tmp/config", "https://user:secret@example.invalid", "https://example.invalid?key=private", "https://example.invalid#fragment"] {
            var invalid = valid; invalid.baseURL = address
            XCTAssertThrowsError(try PipelineAISettingsStore.save(invalid, defaults: defaults))
            XCTAssertEqual(defaults.data(forKey: PipelineAISettingsStore.defaultsKey), before)
        }
        var invalid = valid; invalid.apiKey = "  "
        XCTAssertThrowsError(try PipelineAISettingsStore.save(invalid, defaults: defaults))
        invalid = valid; invalid.model = "  "
        XCTAssertThrowsError(try PipelineAISettingsStore.save(invalid, defaults: defaults))
        XCTAssertEqual(defaults.data(forKey: PipelineAISettingsStore.defaultsKey), before)
    }

    func testCorruptedSavedConfigIsPreservedAndReported() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let broken = Data("{broken".utf8)
        defaults.set(broken, forKey: PipelineAISettingsStore.defaultsKey)
        let loaded = PipelineAISettingsStore.load(defaults: defaults, sampleURL: nil)
        XCTAssertNotNil(loaded.error)
        XCTAssertFalse(loaded.inherited)
        XCTAssertEqual(defaults.data(forKey: PipelineAISettingsStore.defaultsKey), broken)
    }

    func testPreviousConfigIsReadOnlyFallbackAndFreshDefaultUsesFlash() throws {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(PipelineAISettingsStore.load(defaults: defaults, sampleURL: nil).config.model, "deepseek-flash")
        let old = PipelineAISettings(baseURL: "https://example.invalid", apiKey: "old-test-key", model: "deepseek-flash")
        let data = try JSONEncoder().encode(old)
        defaults.set(data, forKey: PipelineAISettingsStore.legacyKey)
        XCTAssertEqual(PipelineAISettingsStore.load(defaults: defaults, sampleURL: nil).config, old)
        XCTAssertNil(defaults.data(forKey: PipelineAISettingsStore.defaultsKey))
        XCTAssertEqual(defaults.data(forKey: PipelineAISettingsStore.legacyKey), data)
    }

    func testPromptOverridesRoundTripAndEmptyFallsBack() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(PipelinePromptSettingsStore.load(defaults: defaults), PipelinePromptSettings())
        PipelinePromptSettingsStore.save(PipelinePromptSettings(split: "自定义分集规则"), defaults: defaults)
        XCTAssertEqual(PipelinePromptSettingsStore.load(defaults: defaults).split, "自定义分集规则")
        XCTAssertEqual(PipelinePromptStore.effective("", fallback: "默认"), "默认")
        XCTAssertEqual(PipelinePromptStore.effective("  \n", fallback: "默认"), "默认")
        XCTAssertEqual(PipelinePromptStore.effective("自定义", fallback: "默认"), "自定义")
        defaults.set(Data("{broken".utf8), forKey: PipelinePromptSettingsStore.defaultsKey)
        XCTAssertEqual(PipelinePromptSettingsStore.load(defaults: defaults), PipelinePromptSettings())
    }
}
