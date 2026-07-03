import Testing

@testable import Barktor

struct EngineUsedLabelTests {
    @Test func parakeetIsBareIdentifier() {
        #expect(AppCoordinator.engineUsedLabel(engine: .parakeet, modelName: "ignored") == "parakeet")
    }

    @Test func whisperCarriesModelName() {
        #expect(
            AppCoordinator.engineUsedLabel(engine: .whisper, modelName: "openai_whisper-small")
                == "whisper:openai_whisper-small")
    }
}

struct ModelShortLabelTests {
    @Test func curatedLabelsAreCompacted() {
        #expect(
            ModelManager.shortLabel(forModel: "openai_whisper-large-v3-v20240930_turbo_632MB")
                == "Large V3 Turbo")
        #expect(ModelManager.shortLabel(forModel: "openai_whisper-tiny.en") == "Tiny EN")
        #expect(ModelManager.shortLabel(forModel: "openai_whisper-small") == "Small")
    }

    @Test func unknownIdFallsBackToTrimmedId() {
        #expect(ModelManager.shortLabel(forModel: "openai_whisper-medium") == "medium")
        #expect(ModelManager.shortLabel(forModel: "custom-model") == "custom-model")
    }
}
