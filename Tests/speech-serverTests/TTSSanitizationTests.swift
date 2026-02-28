import XCTest
@testable import speech_server

final class TTSSanitizationTests: XCTestCase {

    // MARK: - Plain text pass-through

    func testPlainTextUnchanged() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello, world!"), "Hello, world!")
    }

    func testEmptyStringUnchanged() {
        XCTAssertEqual(sanitizeTextForPocketTTS(""), "")
    }

    func testPunctuationAndNumbersUnchanged() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Item 1: cost $3.50 (approx)."), "Item 1: cost $3.50 (approx).")
    }

    // MARK: - Emoji removal

    func testLeadingEmojiStripped() {
        XCTAssertEqual(sanitizeTextForPocketTTS("🎉 Party time!"), "Party time!")
    }

    func testTrailingEmojiStripped() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Great job! 👍"), "Great job!")
    }

    func testEmojiInMiddleStripped() {
        XCTAssertEqual(sanitizeTextForPocketTTS("I love 🍕 pizza"), "I love pizza")
    }

    func testMultipleEmojiStripped() {
        XCTAssertEqual(sanitizeTextForPocketTTS("🌟 Stars 🌟 everywhere 🌟"), "Stars everywhere")
    }

    func testEmojiOnlyInputBecomesEmpty() {
        XCTAssertEqual(sanitizeTextForPocketTTS("🎊🎉🎈"), "")
    }

    // MARK: - Compound emoji (ZWJ sequences)

    func testFamilyEmojiZWJSequenceStripped() {
        // 👨‍👩‍👧 = man ZWJ woman ZWJ girl; no space between text and emoji so
        // no orphaned space is left behind after stripping.
        XCTAssertEqual(sanitizeTextForPocketTTS("Meet the family👨‍👩‍👧."), "Meet the family.")
    }

    func testProfessionEmojiZWJSequenceStripped() {
        // 👩‍💻 = woman ZWJ laptop
        XCTAssertEqual(sanitizeTextForPocketTTS("She is a 👩‍💻 developer."), "She is a developer.")
    }

    // MARK: - Text-default-presentation emoji

    func testTextDefaultPresentationEmojiStripped() {
        // 🌩 U+1F329 and ⚡ U+26A1 have Emoji=Yes but Emoji_Presentation=No;
        // the old isEmojiPresentation filter missed them.
        XCTAssertEqual(sanitizeTextForPocketTTS("🌩 Storm warning ⚡"), "Storm warning")
    }

    // MARK: - Skin-tone modifiers

    func testSkinToneModifierStripped() {
        // 👋🏽 = waving hand + medium skin tone.
        // Skin-tone modifiers (U+1F3FB–U+1F3FF) are caught by the main
        // isEmoji && value >= 0x231A condition.
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello 👋🏽"), "Hello")
    }

    // MARK: - Flag emoji (tag character sequences)

    func testFlagEmojiStripped() {
        // 🏴󠁧󠁢󠁳󠁣󠁴󠁿 = Scotland flag (regional indicator + tag characters)
        let scotland = "Scotland 🏴󠁧󠁢󠁳󠁣󠁴󠁿 is beautiful."
        XCTAssertEqual(sanitizeTextForPocketTTS(scotland), "Scotland is beautiful.")
    }

    // MARK: - Variation selectors

    func testVariationSelectorStripped() {
        // ☺︎ vs ☺️ — U+263A + U+FE0F (emoji variation selector)
        let withSelector = "Nice \u{263A}\u{FE0F} day"
        // U+263A (☺) alone is not isEmojiPresentation, so it stays; U+FE0F is stripped
        let result = sanitizeTextForPocketTTS(withSelector)
        XCTAssertFalse(result.unicodeScalars.contains { $0.value == 0xFE0F })
    }

    // MARK: - Whitespace handling

    func testLeadingWhitespaceTrimmed() {
        XCTAssertEqual(sanitizeTextForPocketTTS("   Hello"), "Hello")
    }

    func testTrailingWhitespaceTrimmed() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello   "), "Hello")
    }

    func testInternalWhitespaceCollapsed() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello   world"), "Hello world")
    }

    func testNewlinesCollapsed() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello\nworld"), "Hello world")
    }

    func testEmojiRemovalCollapsesAdjacentSpaces() {
        // "Hello [space] 😊 [space] world" → after strip → "Hello   world" → collapse → "Hello world"
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello 😊 world"), "Hello world")
    }

    func testWhitespaceOnlyInputBecomesEmpty() {
        XCTAssertEqual(sanitizeTextForPocketTTS("   \t\n  "), "")
    }

    // MARK: - ASCII emoji-capable characters are preserved

    func testAsteriskPreserved() {
        // * has Unicode Emoji property but not EmojiPresentation; must not be stripped
        XCTAssertEqual(sanitizeTextForPocketTTS("Important*"), "Important*")
    }

    func testHashPreserved() {
        // # has Unicode Emoji property but not EmojiPresentation; must not be stripped
        XCTAssertEqual(sanitizeTextForPocketTTS("#1 hit"), "#1 hit")
    }

    func testDigitsPreserved() {
        // 0–9 have Unicode Emoji property but not EmojiPresentation
        XCTAssertEqual(sanitizeTextForPocketTTS("Call 999"), "Call 999")
    }
}
