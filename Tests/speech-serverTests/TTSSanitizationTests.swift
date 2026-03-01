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

    // MARK: - Text emoticon removal

    func testSmileRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Great job :)"), "Great job")
    }

    func testSmileWithNoseRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Nice :-) work"), "Nice work")
    }

    func testFrownRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Too bad :("), "Too bad")
    }

    func testGrinRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Haha :D"), "Haha")
    }

    func testGrinWithNoseRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Haha :-D"), "Haha")
    }

    func testWinkRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Just kidding ;)"), "Just kidding")
    }

    func testTongueOutRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Silly :P"), "Silly")
    }

    func testXDRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("That's funny XD"), "That's funny")
    }

    func testXdLowercaseRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("lol xd"), "lol")
    }

    func testHeartRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("I love it <3"), "I love it")
    }

    func testCaretFaceRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Yay ^_^"), "Yay")
    }

    func testEmoticonMidSentenceRemoved() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello :) world"), "Hello world")
    }

    // Emoticon-like sequences that must NOT be stripped

    func testColonInURLNotRemoved() {
        // Colon in a URL is preceded by a word character — lookbehind must protect it
        XCTAssertEqual(sanitizeTextForPocketTTS("http://example.com"), "http://example.com")
    }

    func testParensInTextNotRemoved() {
        // Parentheses not preceded by an emoticon eye character
        XCTAssertEqual(sanitizeTextForPocketTTS("Item 1 (approx)."), "Item 1 (approx).")
    }

    func testColonFollowedByWordNotRemoved() {
        // "Note:" — colon preceded by a word character, so not an emoticon eye
        XCTAssertEqual(sanitizeTextForPocketTTS("Note: see below"), "Note: see below")
    }

    // MARK: - Space-before-punctuation normalisation

    func testSpaceBeforePeriodFixed() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello ."), "Hello.")
    }

    func testSpaceBeforeCommaFixed() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello , world"), "Hello, world")
    }

    func testSpaceBeforeExclamationFixed() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello !"), "Hello!")
    }

    func testSpaceBeforeQuestionFixed() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Really ?"), "Really?")
    }

    func testMultipleSpacesBeforePunctuationFixed() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello   ."), "Hello.")
    }

    func testNormalPunctuationUnchanged() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Hello, world!"), "Hello, world!")
    }

    func testSpacedPunctuationMidSentenceFixed() {
        XCTAssertEqual(sanitizeTextForPocketTTS("Wait , really ?"), "Wait, really?")
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
