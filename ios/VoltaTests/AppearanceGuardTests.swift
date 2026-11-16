import XCTest

/// Volta follows the system appearance (docs/APPEARANCE.md). These checks read
/// the app and widget sources and fail when someone forces a colour scheme or
/// writes a colour that cannot adapt, outside the theme files.
///
/// A line may opt out with an `// appearance: <reason>` comment, for a colour
/// that is the same in both modes by design (a charger badge, a marker rim) or
/// an alpha-only mask. A colour inside `Color(light:dark:)` adapts, so it passes.
final class AppearanceGuardTests: XCTestCase {
    /// `ios/`, found from this file's path (the simulator shares the host's file system).
    private static let iosRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Where colour literals live: the tokens themselves.
    private static let themeFiles: Set<String> = ["Volta/DesignSystem/Theme.swift", "VoltaWidgets/Extension/Theme.swift"]

    /// The one place a scheme is forced on purpose: the trip share card renders
    /// dark so every shared image looks the same (docs/APPEARANCE.md). A forced
    /// scheme anywhere else fails, whatever comment it carries.
    private static let allowedForcedSchemes: [String: Int] = ["Volta/Features/History/Trip/TripShare.swift": 1]

    /// Matched over a whole file (comments and strings removed), so a call split
    /// across lines is still caught. `@Environment(\.colorScheme)` reads the scheme
    /// and is fine; `.environment(\.colorScheme, …)` sets it.
    private static let forcedScheme = try! NSRegularExpression(
        pattern: #"preferredColorScheme\s*\(|\.environment\s*\(\s*\\\.colorScheme|overrideUserInterfaceStyle|UIUserInterfaceStyle"#)
    private static let colorLiteral = try! NSRegularExpression(
        pattern: #"Color\s*\(\s*(hex|red|hue|white)\s*:|Color\s*\(\s*\.sRGB|UIColor\s*\(|(?<![A-Za-z0-9_])(Color)?\.(white|black|gray|red|green|blue|orange|yellow|pink|purple|teal|cyan|mint|indigo|brown)(?![A-Za-z0-9_])"#)
    /// The start of an adaptive colour, however it is spaced.
    private static let adaptiveStart = try! NSRegularExpression(pattern: #"Color\s*\(\s*light\s*:"#)

    struct Violation: CustomStringConvertible {
        var file: String
        var line: Int
        var text: String
        var description: String { "\(file):\(line): \(text)" }
    }

    /// The Swift sources the app and widgets ship, as paths relative to `ios/`.
    static func sources() throws -> [String] {
        var out: [String] = []
        for dir in ["Volta", "VoltaWidgets"] {
            let base = iosRoot.appendingPathComponent(dir)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                out.append(dir + url.path.dropFirst(base.path.count))
            }
        }
        return out.sorted()
    }

    /// The code part of a line: no trailing comment, no string contents.
    static func code(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { return "" }
        var code = line.replacingOccurrences(of: #""[^"]*""#, with: "\"\"", options: .regularExpression)
        if let r = code.range(of: "//") { code = String(code[..<r.lowerBound]) }
        return code
    }

    /// `code` with every `Color(light: …, dark: …)` call removed, so the literals
    /// that build an adaptive colour pass and any other literal does not. A call
    /// may span lines; its newlines are kept so line numbers still line up.
    static func withoutAdaptiveColors(_ code: String) -> String {
        var out = "", rest = code
        while let match = adaptiveStart.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let start = Range(match.range, in: rest)?.lowerBound {
            out += rest[..<start]
            var depth = 0, index = start
            while index < rest.endIndex {
                if rest[index] == "(" { depth += 1 }
                if rest[index] == ")" { depth -= 1; if depth == 0 { index = rest.index(after: index); break } }
                index = rest.index(after: index)
            }
            out += "ADAPTIVE" + String(repeating: "\n", count: rest[start..<index].filter { $0 == "\n" }.count)
            rest = String(rest[index...])
        }
        return out + rest
    }

    /// Violations in one file's text; `path` decides what is allowed.
    static func violations(in text: String, path: String) -> [Violation] {
        var found: [Violation] = []
        // One line ending, so a CRLF file numbers its lines the same way.
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        let codeLines = lines.map(code)

        // Forced schemes, over the whole file so a split call is caught.
        let joined = codeLines.joined(separator: "\n")
        let matches = forcedScheme.matches(in: joined, range: NSRange(joined.startIndex..., in: joined))
        if matches.count > allowedForcedSchemes[path, default: 0] {
            for match in matches {
                let prefix = joined[..<Range(match.range, in: joined)!.lowerBound]
                let line = prefix.filter { $0 == "\n" }.count
                found.append(Violation(file: path, line: line + 1, text: lines[line].trimmingCharacters(in: .whitespaces)))
            }
        }

        // Colour literals, over the whole file so a call split across lines is
        // caught, reported once per line; the theme files hold the tokens.
        guard !themeFiles.contains(path) else { return found }
        let literals = withoutAdaptiveColors(joined)
        var flagged = Set<Int>()
        for match in colorLiteral.matches(in: literals, range: NSRange(literals.startIndex..., in: literals)) {
            let line = literals[..<Range(match.range, in: literals)!.lowerBound].filter { $0 == "\n" }.count
            guard !lines[line].contains("// appearance:"), flagged.insert(line).inserted else { continue }
            found.append(Violation(file: path, line: line + 1, text: lines[line].trimmingCharacters(in: .whitespaces)))
        }
        return found.sorted { $0.line < $1.line }
    }

    func testSourcesAreFound() throws {
        let files = try Self.sources()
        XCTAssertGreaterThan(files.count, 100, "expected the app's sources under \(Self.iosRoot.path)")
        XCTAssertTrue(files.contains("Volta/DesignSystem/Theme.swift"))
        XCTAssertTrue(files.contains { $0.hasPrefix("VoltaWidgets/Extension/") })
    }

    func testNoForcedSchemeOrFixedColourOutsideTheTheme() throws {
        var all: [Violation] = []
        for path in try Self.sources() {
            let text = try String(contentsOf: Self.iosRoot.appendingPathComponent(path), encoding: .utf8)
            all += Self.violations(in: text, path: path)
        }
        XCTAssert(all.isEmpty, """
            Volta follows the system appearance. Use a token or Color(light:dark:), or mark a \
            colour that is the same in both modes with `// appearance: <reason>` (docs/APPEARANCE.md):
            \(all.map(\.description).joined(separator: "\n"))
            """)
    }

    func testInfoPlistsDoNotForceAStyle() throws {
        for path in ["Volta/Info.plist", "VoltaWidgets/Info.plist", "project.yml", "project.widgets.yml"] {
            let text = try String(contentsOf: Self.iosRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(text.contains("UIUserInterfaceStyle"), "\(path) forces an interface style")
        }
    }

    // MARK: The guard itself

    func testGuardCatchesWhatItShould() {
        let bad = [
            ".preferredColorScheme(.dark)",
            "Map().environment(\\.colorScheme, .dark)",
            "window.overrideUserInterfaceStyle = .dark",
            "Text(\"a\").foregroundStyle(.white)",
            "Rectangle().fill(Color.black.opacity(0.4))",
            "static let x = Color(hex: 0x123456)",
            "let c = UIColor(red: 1, green: 0, blue: 0, alpha: 1)",
            ".foregroundStyle(.gray)",
            ".foregroundStyle(.red)",
            "let c = Color(hue: 0.5, saturation: 1, brightness: 1)",
            "let c = Color(light: .white, dark: .black); let d = Color.white",
            "Text(\"a\").preferredColorScheme(.dark)  // appearance: fixed (no)",
        ]
        for line in bad {
            XCTAssertEqual(Self.violations(in: line, path: "Volta/Features/X.swift").count, 1, line)
        }
        // Spacing and line breaks don't hide a literal.
        XCTAssertEqual(Self.violations(in: "let c = Color( hue: 0.5, saturation: 1, brightness: 1)", path: "Volta/Features/X.swift").count, 1)
        XCTAssertEqual(Self.violations(in: "let c = Color(\n    red: 1, green: 0, blue: 0)", path: "Volta/Features/X.swift").count, 1)
        XCTAssertEqual(Self.violations(in: "let c = Color(light: .white,\n    dark: .black)\nlet d = Color.white", path: "Volta/Features/X.swift").map(\.line), [3])
        // CRLF line endings number lines the same way.
        XCTAssertEqual(Self.violations(in: "let a = 8\r\nlet b = Color(\"Brand\") // appearance: fixed (logo)\r\nlet c = Color.red", path: "Volta/Features/X.swift").map(\.line), [3])
        XCTAssertEqual(Self.violations(in: "let a = Color(light: .white,\r\n    dark: .black)\r\nlet d = Color.white", path: "Volta/Features/X.swift").map(\.line), [3])
        // A forced scheme split across lines.
        XCTAssertEqual(Self.violations(in: "Map()\n    .environment(\n        \\.colorScheme, .dark)", path: "Volta/Features/X.swift").count, 1)
        // The share card's one allowed forced scheme; a second one fails.
        let share = "Volta/Features/History/Trip/TripShare.swift"
        XCTAssertTrue(Self.violations(in: "a.environment(\\.colorScheme, .dark)", path: share).isEmpty)
        XCTAssertFalse(Self.violations(in: "a.environment(\\.colorScheme, .dark)\nb.preferredColorScheme(.dark)", path: share).isEmpty)
    }

    func testGuardAllowsWhatItShould() {
        let good = [
            "Text(\"a\").foregroundStyle(.voltaTextPrimary)",
            "static let x = Color(light: 0xFFFFFF, dark: 0x000000)",
            "static let plate = Color(light: .white.opacity(0.85), dark: .black.opacity(0.72))",
            "Circle().fill(Color.white)  // appearance: fixed (marker rim)",
            "// Black text on white, never .preferredColorScheme(.dark)",
            "let s = \"white .black\".trimmingCharacters(in: .whitespaces)",
            ".foregroundStyle(Color.voltaInk.opacity(0.06))",
            "@Environment(\\.colorScheme) private var scheme",
            ".foregroundStyle(ScreenKit.blue)",
            "static let a = Color(light: Color(hex: 0x6C6C70), dark: Color(hex: 0x9E9E9E).opacity(0.5))",
        ]
        for line in good {
            XCTAssertTrue(Self.violations(in: line, path: "Volta/Features/X.swift").isEmpty, line)
        }
        // An adaptive colour split across lines, however it is spaced.
        for text in ["static let a = Color(light: .white,\n    dark: .black)",
                     "static let a = Color(\n    light: Color(hex: 0x6C6C70),\n    dark: Color(hex: 0x9E9E9E).opacity(0.5)\n)",
                     "Circle().fill(\n    Color.white  // appearance: fixed (marker rim)\n)"] {
            XCTAssertTrue(Self.violations(in: text, path: "Volta/Features/X.swift").isEmpty, text)
        }
        XCTAssertTrue(Self.violations(in: "static let card = Color(hex: 0x17191C)", path: "VoltaWidgets/Extension/Theme.swift").isEmpty)
        XCTAssertEqual(Self.violations(in: ".preferredColorScheme(.light)", path: "Volta/DesignSystem/Theme.swift").count, 1,
                       "the theme may hold literals, never a forced scheme")
    }
}
