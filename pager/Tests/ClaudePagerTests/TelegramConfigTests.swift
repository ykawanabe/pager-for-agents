import XCTest
@testable import ClaudePager

final class TelegramConfigTests: XCTestCase {
    private var envPath: String!
    private var accessPath: String!

    override func setUpWithError() throws {
        let tmp = NSTemporaryDirectory() + "ClaudePagerTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        envPath = tmp + "/.env"
        accessPath = tmp + "/access.json"
    }

    override func tearDownWithError() throws {
        let dir = (envPath as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - .env parsing

    func test_load_returnsEmptyTokenWhenFileMissing() {
        let c = TelegramConfig(envPath: envPath, accessPath: accessPath)
        XCTAssertEqual(c.token, "")
    }

    func test_load_parsesPlainToken() throws {
        try "TELEGRAM_BOT_TOKEN=abc123:secretkey\n".write(toFile: envPath, atomically: true, encoding: .utf8)
        let c = TelegramConfig(envPath: envPath, accessPath: accessPath)
        XCTAssertEqual(c.token, "abc123:secretkey")
    }

    /// Tokens written by hand (or by other tools) are often quoted. Strip
    /// surrounding double quotes so the in-memory value is the actual token,
    /// not a string with embedded quote characters.
    func test_load_stripsSurroundingQuotes() throws {
        try "TELEGRAM_BOT_TOKEN=\"abc123:secretkey\"\n".write(toFile: envPath, atomically: true, encoding: .utf8)
        let c = TelegramConfig(envPath: envPath, accessPath: accessPath)
        XCTAssertEqual(c.token, "abc123:secretkey")
    }

    /// Real .env files often have other keys mixed in. The reader should
    /// pick out only TELEGRAM_BOT_TOKEN and ignore the rest.
    func test_load_ignoresOtherKeys() throws {
        let body = """
        # comment
        OTHER_KEY=something
        TELEGRAM_BOT_TOKEN=correct-token
        ANOTHER=value
        """
        try body.write(toFile: envPath, atomically: true, encoding: .utf8)
        let c = TelegramConfig(envPath: envPath, accessPath: accessPath)
        XCTAssertEqual(c.token, "correct-token")
    }

    // MARK: - .env round-trip

    /// Writing a token must produce a file whose token re-reads cleanly.
    /// Catches accidental quote-mangling, trailing-newline regressions, etc.
    func test_save_thenLoad_preservesToken() throws {
        let writer = TelegramConfig(envPath: envPath, accessPath: accessPath)
        writer.token = "fresh-token-99"
        writer.save()

        let reader = TelegramConfig(envPath: envPath, accessPath: accessPath)
        XCTAssertEqual(reader.token, "fresh-token-99")
    }

    /// File permission tightening is part of the security contract: never
    /// leave a token readable by other users on the machine.
    func test_save_setsRestrictivePermissions() throws {
        let c = TelegramConfig(envPath: envPath, accessPath: accessPath)
        c.token = "any"
        c.save()
        let attrs = try FileManager.default.attributesOfItem(atPath: envPath)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perm & 0o777, 0o600, "expected 0600, got \(String(perm, radix: 8))")
    }

    // MARK: - access.json (allowlist)
    //
    // Pager no longer reads or writes `allowFrom` / `dmPolicy`. In MULTI_TOPIC
    // mode the poller only honors paired.json's `user_id` — the allowlist UI
    // was a misleading no-op (removed 2026-05-16). Tests that asserted the
    // old read/write behavior are intentionally deleted; the only contract
    // worth pinning is "saving doesn't clobber existing allowFrom" so users
    // who relied on the old single-topic path don't lose their allowlist on
    // a Pager save.

    func test_save_preservesExistingAllowFrom() throws {
        try #"{"allowFrom":["111","222"],"dmPolicy":"allowlist"}"#
            .write(toFile: accessPath, atomically: true, encoding: .utf8)
        let c = TelegramConfig(envPath: envPath, accessPath: accessPath)
        c.ackReaction = "🔥"
        c.save()

        let data = try Data(contentsOf: URL(fileURLWithPath: accessPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["allowFrom"] as? [String], ["111", "222"],
                       "Pager save should leave existing allowFrom alone")
        XCTAssertEqual(json?["dmPolicy"] as? String, "allowlist")
        XCTAssertEqual(json?["ackReaction"] as? String, "🔥")
    }

    // MARK: - access.json (ackReaction)

    /// Missing key → empty string in memory. The Picker's "Off" option binds
    /// to "" so an absent field shows up correctly as "no reaction."
    func test_load_missingAckReactionReturnsEmpty() throws {
        try #"{"allowFrom":["123"]}"#.write(toFile: accessPath, atomically: true, encoding: .utf8)
        let c = TelegramConfig(envPath: envPath, accessPath: accessPath)
        XCTAssertEqual(c.ackReaction, "")
    }

    func test_load_parsesAckReaction() throws {
        let json = #"{"allowFrom":["123"],"ackReaction":"👀"}"#
        try json.write(toFile: accessPath, atomically: true, encoding: .utf8)
        let c = TelegramConfig(envPath: envPath, accessPath: accessPath)
        XCTAssertEqual(c.ackReaction, "👀")
    }

    /// Setting an emoji must round-trip: write → re-read returns the same.
    func test_save_thenLoad_preservesAckReaction() throws {
        let writer = TelegramConfig(envPath: envPath, accessPath: accessPath)
        writer.ackReaction = "🔥"
        writer.save()

        let reader = TelegramConfig(envPath: envPath, accessPath: accessPath)
        XCTAssertEqual(reader.ackReaction, "🔥")
    }

    /// Empty string must REMOVE the key entirely, not leave "ackReaction":"".
    /// Plugin treats both as falsy but explicit omission keeps the file clean
    /// and matches how install.sh writes the initial access.json.
    func test_save_emptyAckReactionRemovesKey() throws {
        // Seed a file that already has the key set.
        try #"{"allowFrom":["1"],"ackReaction":"👀"}"#.write(toFile: accessPath, atomically: true, encoding: .utf8)

        let c = TelegramConfig(envPath: envPath, accessPath: accessPath)
        XCTAssertEqual(c.ackReaction, "👀")
        c.ackReaction = ""
        c.save()

        let data = try Data(contentsOf: URL(fileURLWithPath: accessPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(json?["ackReaction"], "expected key removed, got: \(String(describing: json?["ackReaction"]))")
    }

    /// Whitespace-only input is equivalent to "off" — strip and remove the key.
    /// Guards against a user typing a space and accidentally writing a reaction
    /// that Telegram would reject.
    func test_save_whitespaceAckReactionRemovesKey() throws {
        let c = TelegramConfig(envPath: envPath, accessPath: accessPath)
        c.ackReaction = "   "
        c.save()

        let data = try Data(contentsOf: URL(fileURLWithPath: accessPath))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(json?["ackReaction"])
    }
}
