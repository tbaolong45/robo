// The footer's receipts: what the reply claims against what robo-guard recorded (a labelled click, a send key, a file
// write). The record format is the guard's `_receipt` in hermes/plugins/robo-guard/__init__.py.
import Foundation
import Testing
@testable import RoboCore

private let OUTLOOK = "outlook.office.com"
private func click(_ label: String, host: String = OUTLOOK, ok: Bool = true) -> Evidence {
    Evidence(tool: "browser_click", what: label, host: host, ok: ok)
}
private func wrote(_ path: String) -> Evidence { Evidence(tool: "write_file", what: path, host: OUTLOOK) }  // the host is the last page, not where the file went
private let SENT = "✓ sent · \(OUTLOOK)"

@Suite struct ReceiptTests {
    @Test(arguments: [
        // a claim with a record, a claim without one, no claim and no record
        ("I sent the email to Anna.", [click("Send")], [SENT]),
        ("I sent the email to Anna.", [], ["⚠ unverified: sent (no send was recorded)"]),
        ("Here is the draft.", [], []),
        // a record of an irreversible step the reply did not name still shows
        ("Here is the draft.", [click("Send")], [SENT]),
        ("Here is the draft.", [click("Delete")], ["✓ deleted · \(OUTLOOK)"]),
        ("Here is the draft.", [click("Move to Junk")], ["✓ moved · \(OUTLOOK)"]),
        // a file write alone is no news (the footer already names the notes), but it backs "saved"
        ("Here is the draft.", [wrote("~/Documents/Robo/Drafts/Mail.md")], []),
        ("I saved it in Obsidian.", [wrote("~/Documents/Robo/Drafts/Mail.md")], ["✓ saved · Mail.md"]),
        ("I saved it in Obsidian.", [], ["⚠ unverified: saved (no save was recorded)"]),
        // every word of the claim list
        ("It was replied to.", [click("Send")], [SENT]),
        ("I forwarded it.", [], ["⚠ unverified: forwarded (no send was recorded)"]),
        ("Posted in the channel.", [click("Post", host: "teams.microsoft.com")], ["✓ sent · teams.microsoft.com"]),
        ("I deleted the mail.", [], ["⚠ unverified: deleted (no delete or move was recorded)"]),
        ("I moved it to Junk.", [click("Junk")], ["✓ moved · \(OUTLOOK)"]),
        ("It is booked.", [click("Save")], ["✓ saved · \(OUTLOOK)"]),
        ("It is scheduled for Friday.", [], ["⚠ unverified: scheduled (no calendar save was recorded)"]),
        ("Added to the calendar.", [], ["⚠ unverified: added to calendar (no calendar save was recorded)"]),
        ("I added it to my calendar.", [click("Create")], ["✓ saved · \(OUTLOOK)"]),
        // a note is no booking
        ("It is booked.", [wrote("a.md")], ["⚠ unverified: booked (no calendar save was recorded)"]),
        // opening a reply or a forward sends nothing; the Send click does
        ("I replied to Anna.", [click("Reply")], ["⚠ unverified: replied (no send was recorded)"]),
        ("I forwarded it.", [click("Forward")], ["⚠ unverified: forwarded (no send was recorded)"]),
        ("I replied.", [click("Reply"), click("Send and archive")], [SENT]),
        // a send key, a failed call, a step with no label to read
        ("Sent.", [Evidence(tool: "browser_press", what: "press Control+Enter", host: "teams.microsoft.com")], ["✓ sent · teams.microsoft.com"]),
        ("Sent.", [click("Send", ok: false)], ["⚠ unverified: sent (no send was recorded)"]),
        ("Sent.", [Evidence(tool: "computer_use", what: "click in Microsoft Outlook")], ["⚠ unverified: sent (no send was recorded)"]),
        // Vietnamese, as typed on a Mac (decomposed) or not, in any case
        ("Mình đã gửi thư rồi.", [click("Gửi")], [SENT]),
        ("Mình đã gửi thư rồi.", [], ["⚠ unverified: đã gửi (no send was recorded)"]),
        ("Mình \u{0111}a\u{0303} gu\u{031B}\u{0309}i thư rồi.", [], ["⚠ unverified: đã gửi (no send was recorded)"]),
        ("ĐÃ LƯU rồi.", [], ["⚠ unverified: đã lưu (no save was recorded)"]),
        ("Em đã   đặt lịch.", [], ["⚠ unverified: đã đặt (no calendar save was recorded)"]),
        ("Đã xóa thư đó.", [click("Xóa")], ["✓ deleted · \(OUTLOOK)"]),
        ("Mình đã trả lời Anna.", [], ["⚠ unverified: đã trả lời (no send was recorded)"]),
        // not claims: negated, still to come, or a place
        ("I have not sent it yet.", [], []),
        ("I haven't sent anything.", [], []),
        ("It can be sent once you check it.", [], []),
        ("I did not. Sent items are in the folder.", [], []),
        ("Look in your Sent folder.", [], []),
        ("Chưa gửi, đã lưu nháp.", [], ["⚠ unverified: đã lưu (no save was recorded)"]),
        // whole words only
        ("I removed the consent line and the presented slides.", [], []),
    ] as [(String, [Evidence], [String])])
    func claimsAgainstReceipts(reply: String, evidence: [Evidence], want: [String]) {
        #expect(Receipt.lines(reply: reply, evidence: evidence) == want)
    }

    @Test func manyClaimsGiveWarningsFirstThenWhatWasRecorded() {
        let lines = Receipt.lines(reply: "I saved the note, booked the meeting and moved the mail. I also sent it and replied.",
                                  evidence: [wrote("~/Notes/Plan.md"), click("Save")])
        #expect(lines == ["⚠ unverified: moved (no delete or move was recorded)", "⚠ unverified: sent (no send was recorded)",
                          "✓ saved · Plan.md", "✓ saved · \(OUTLOOK)"])
    }

    @Test func oneLinePerActEvenWhenTheReplyUsesTwoWords() {
        #expect(Receipt.lines(reply: "I sent it, and replied too.", evidence: []) == ["⚠ unverified: sent (no send was recorded)"])
    }

    @Test func theSameStepRecordedAgainCountsOnce() {
        #expect(Receipt.lines(reply: "I sent them.", evidence: Array(repeating: click("Send"), count: 3)) == ["✓ sent ×3 · \(OUTLOOK)"])
        #expect(Receipt.lines(reply: "", evidence: [click("Send"), click("Send", host: "teams.microsoft.com")])
                == [SENT, "✓ sent · teams.microsoft.com"])
    }

    @Test func neverMoreThanFourLinesAndTheWarningsStay() {
        let hosts = (1...6).map { "site\($0).example" }
        let lines = Receipt.lines(reply: "I moved it.", evidence: hosts.map { click("Send", host: $0) })
        #expect(lines.count == 4 && lines[0] == "⚠ unverified: moved (no delete or move was recorded)")
        #expect(lines[1...] == ["✓ sent · site1.example", "✓ sent · site2.example", "✓ sent · site3.example"])
    }

    @Test func aFooterLineNeverEchoesTypedOrPageText() {
        let evidence = [click("Send to anna@example.com: my password is hunter2"), wrote("/Users/jane/secret plans.md")]
        let lines = Receipt.lines(reply: "Sent. I saved it.", evidence: evidence)
        #expect(lines == [SENT, "✓ saved · secret plans.md"])
        #expect(!lines.joined().contains("hunter2") && !lines.joined().contains("anna"))
    }

    @Test func anEmptyReplyAndNoReceiptsGiveNothing() {
        #expect(Receipt.lines(reply: "", evidence: []).isEmpty)
    }
}

@Suite struct ReceiptLogTests {
    private func file(_ lines: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("robo-receipts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("receipts.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A line as robo-guard writes it (`_receipt`): ISO 8601 to the second with the local offset.
    private func row(_ ts: String, tool: String = "browser_click", what: String = "Send", host: String = OUTLOOK, ok: Bool = true) -> String {
        #"{"ts": "\#(ts)", "tool": "\#(tool)", "label_or_path": "\#(what)", "host": "\#(host)", "ok": \#(ok)}"#
    }

    @Test func aMissingFileIsNoReceipts() {
        #expect(ReceiptLog.read(URL(fileURLWithPath: "/nonexistent/receipts.jsonl"), since: 0).isEmpty)
    }

    @Test func onlyThisRunsReceiptsAreRead() throws {
        let start = 1_792_393_402.4  // 2026-10-19T14:03:22+07:00 and a bit: the guard's stamp has no fractions
        let url = try file([
            row("2026-10-19T14:03:20+07:00", what: "Before"), row("2026-10-19T14:03:22+07:00", what: "Same second"),
            row("2026-10-19T07:03:30+00:00", what: "Later, other offset"), row("2026-10-19T14:05:00+07:00", what: "Later"),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(ReceiptLog.read(url, since: start).map(\.what) == ["Same second", "Later, other offset", "Later"])
    }

    @Test func theFieldsAreReadAsTheGuardWritesThem() throws {
        let url = try file([row("2026-10-19T14:03:22+07:00", tool: "patch", what: "~/a.md, ~/b.md", host: "", ok: false)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(ReceiptLog.read(url, since: 0) == [Evidence(tool: "patch", what: "~/a.md, ~/b.md", host: "", ok: false)])
    }

    @Test func badLinesAreSkipped() throws {
        let url = try file(["not json", "", #"{"ts": "yesterday", "tool": "browser_click"}"#, #"{"tool": "x"}"#,
                            row("2026-10-19T14:03:22+07:00", what: "Good")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(ReceiptLog.read(url, since: 0).map(\.what) == ["Good"])
    }

    @Test func onlyTheLastTwoHundredLinesAreRead() throws {
        let url = try file((0..<250).map { row("2026-10-19T14:03:22+07:00", what: "n\($0)") })
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let seen = ReceiptLog.read(url, since: 0)
        #expect(seen.count == ReceiptLog.tail && seen.first?.what == "n50" && seen.last?.what == "n249")
    }

    @Test func aReceiptReadFromTheFileFeedsTheLines() throws {
        let url = try file([row("2026-10-19T14:03:22+07:00")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(Receipt.lines(reply: "Sent!", evidence: ReceiptLog.read(url, since: 0)) == [SENT])
    }
}
