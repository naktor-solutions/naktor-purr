import Testing

@testable import Purr

struct LLMPostProcessorTests {
    @Test func promptCarriesLevelRulesAndText() {
        let p = LLMPostProcessor.prompt(
            for: "hola mundo", level: .cleanup, customInstructions: "")
        // Gemma chat template wrapping (same as EditInterpreter).
        #expect(p.hasPrefix("<start_of_turn>user\n"))
        #expect(p.contains("<end_of_turn>\n<start_of_turn>model"))
        // The one non-negotiable cleanup rule and the payload.
        #expect(p.contains("Never change the user's words"))
        #expect(p.contains("hola mundo"))
        // No custom-instructions block when empty.
        #expect(!p.contains("Additional instructions"))
    }

    @Test func promptAppendsCustomInstructions() {
        let p = LLMPostProcessor.prompt(
            for: "x", level: .rewrite, customInstructions: "bullet lists please")
        #expect(p.contains("Additional instructions from the user"))
        #expect(p.contains("bullet lists please"))
        #expect(p.contains("Rewrite"))
    }

    @Test func sanitizeStripsFencesAndWhitespace() {
        #expect(LLMPostProcessor.sanitize("\n```\nhola\n```\n") == "hola")
        #expect(LLMPostProcessor.sanitize("```text\nhola\n```") == "hola")
        #expect(LLMPostProcessor.sanitize("  hola  \n") == "hola")
        #expect(LLMPostProcessor.sanitize("hola\nmundo") == "hola\nmundo")
    }

    @Test func sanitizeNeverStripsContentBearingFenceLines() {
        // Opening fence with no closing fence: not a wrapper, leave untouched.
        #expect(LLMPostProcessor.sanitize("```hello\nworld") == "```hello\nworld")
        // First line carries non-tag content: not a bare fence, leave untouched.
        #expect(LLMPostProcessor.sanitize("```print(x)\n```") == "```print(x)\n```")
    }

    @Test func maxTokensScalesWithInputAndClamps() {
        #expect(LLMPostProcessor.maxTokens(forInputLength: 10) == 256)
        #expect(LLMPostProcessor.maxTokens(forInputLength: 1000) == 1000)
        #expect(LLMPostProcessor.maxTokens(forInputLength: 100_000) == 2000)
    }

    @Test func isFenceOnlyDetectsBareFenceMarkersAndEmptyOutput() {
        #expect(LLMPostProcessor.isFenceOnly("```"))
        #expect(LLMPostProcessor.isFenceOnly("`"))
        #expect(LLMPostProcessor.isFenceOnly(""))
        #expect(!LLMPostProcessor.isFenceOnly("hola"))
    }

    @Test func sanitizePassesThroughLoneBareFence() {
        // Documents the pass-through: sanitize's count >= 2 guard only fires
        // on a matched opening/closing pair, so a single bare fence line is
        // untouched by sanitize - isFenceOnly is what catches it in polish.
        #expect(LLMPostProcessor.sanitize("```") == "```")
    }

    @Test func offLevelPassesThroughUntouched() async {
        let text = "  raw text with, weird punctuation  "
        let out = await LLMPostProcessor.polish(text, level: .off, customInstructions: "")
        #expect(out == text)
    }

    @Test func missingModelFallsBackToInput() async {
        // This CLT machine has no Gemma GGUF installed, so the guard path is
        // exercised for real: polish must return the input unchanged, fast.
        guard !LLMModelManager.isInstalled() else { return }
        let out = await LLMPostProcessor.polish(
            "hola mundo", level: .cleanup, customInstructions: "")
        #expect(out == "hola mundo")
    }
}
