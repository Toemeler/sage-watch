import SwiftUI

/// Digit outlines of Playfair Display (lining figures), extracted once into glyphs.json.
/// Drawing the outlines (instead of text) keeps the time pixel-identical to the prototype and lets digits morph.
struct Glyph {
    let path: Path       // font units, y up
    let advance: Double
}

final class GlyphSet {
    let unitsPerEm: Double
    let digits: [Int: Glyph]
    init(unitsPerEm: Double, digits: [Int: Glyph]) { self.unitsPerEm = unitsPerEm; self.digits = digits }
}

enum Glyphs {
    static let regular: GlyphSet = load("reg")
    static let italic: GlyphSet = load("ita")

    private struct Raw: Decodable { let upm: Double; let digits: [String: RawDigit] }
    private struct RawDigit: Decodable { let d: String; let adv: Double }

    private static let file: [String: Raw] = {
        guard let url = Bundle.main.url(forResource: "glyphs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: Raw].self, from: data) else { return [:] }
        return raw
    }()

    private static func load(_ key: String) -> GlyphSet {
        guard let raw = file[key] else { return GlyphSet(unitsPerEm: 1000, digits: [:]) }
        var out: [Int: Glyph] = [:]
        for (k, v) in raw.digits { if let n = Int(k) { out[n] = Glyph(path: SVGPath.parse(v.d), advance: v.adv) } }
        return GlyphSet(unitsPerEm: raw.upm, digits: out)
    }
}

/// Minimal SVG path parser for the commands the glyph data uses (absolute M L H V Q C Z, plus relative forms).
enum SVGPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var tokens = Tokenizer(d)
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero
        while let next = tokens.peek() {
            if case .command(let c) = next { cmd = c; _ = tokens.next() }
            let rel = cmd.isLowercase
            func pt() -> CGPoint? {
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }
            switch cmd.uppercased().first! {
            case "M":
                guard let p = pt() else { return path }
                path.move(to: p); cur = p; start = p
                cmd = rel ? "l" : "L"            // implicit lineto after moveto
            case "L":
                guard let p = pt() else { return path }
                path.addLine(to: p); cur = p
            case "H":
                guard let x = tokens.number() else { return path }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur)
            case "V":
                guard let y = tokens.number() else { return path }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur)
            case "Q":
                guard let c = pt(), let p = pt() else { return path }
                path.addQuadCurve(to: p, control: c); cur = p
            case "C":
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2); cur = p
            case "Z":
                path.closeSubpath(); cur = start
                if case .command = tokens.peek() {} else if tokens.peek() != nil { cmd = "M" }
                if tokens.peek() == nil { return path }
                continue
            default:
                _ = tokens.next()
            }
        }
        return path
    }

    enum Token: Equatable { case command(Character), number(Double) }

    struct Tokenizer {
        private let chars: [Character]
        private var i = 0
        init(_ s: String) { chars = Array(s) }

        private mutating func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" { i += 1 } }

        mutating func peek() -> Token? { let save = i; let t = next(); i = save; return t }

        mutating func next() -> Token? {
            skip()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c.isLetter && c != "e" && c != "E" { i += 1; return .command(c) }
            var j = i, s = ""
            if j < chars.count, chars[j] == "-" || chars[j] == "+" { s.append(chars[j]); j += 1 }
            var dot = false
            while j < chars.count {
                let ch = chars[j]
                if ch.isNumber { s.append(ch); j += 1 }
                else if ch == "." && !dot { dot = true; s.append(ch); j += 1 }
                else if (ch == "e" || ch == "E"), j + 1 < chars.count {
                    s.append(ch); j += 1
                    if chars[j] == "-" || chars[j] == "+" { s.append(chars[j]); j += 1 }
                } else { break }
            }
            i = j
            return Double(s).map { .number($0) }
        }

        mutating func number() -> Double? {
            if case .number(let v) = peek() { _ = next(); return v }
            return nil
        }
    }
}
