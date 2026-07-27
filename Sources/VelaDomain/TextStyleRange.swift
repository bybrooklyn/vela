import Foundation

/// A run of formatted text inside a message body.
///
/// Signal expresses formatting as ranges over the body rather than as markup, so
/// the text stays plain and the styles ride alongside it.
///
/// **Offsets are UTF-16 code units**, which is what Signal and signal-cli use.
/// Swift's `String` is not indexed that way, so anything crossing this boundary
/// must convert explicitly — a range computed with Swift indices silently
/// corrupts formatting as soon as the text contains an emoji.
public struct TextStyleRange: Hashable, Codable, Sendable {
    public enum Style: String, Hashable, Codable, Sendable, CaseIterable {
        case bold = "BOLD"
        case italic = "ITALIC"
        case strikethrough = "STRIKETHROUGH"
        case monospace = "MONOSPACE"
        case spoiler = "SPOILER"
    }

    /// Offset in UTF-16 code units from the start of the body.
    public var start: Int
    /// Length in UTF-16 code units.
    public var length: Int
    public var style: Style

    public init(start: Int, length: Int, style: Style) {
        self.start = start
        self.length = length
        self.style = style
    }

    public var isEmpty: Bool { length <= 0 }

    /// The signal-cli `--text-style` argument: `start:length:STYLE`.
    public var commandArgument: String { "\(start):\(length):\(style.rawValue)" }

    /// Clamps to the bounds of a body, dropping anything that falls outside.
    /// Ranges arrive from the network and cannot be trusted to fit.
    public func clamped(toUTF16Length limit: Int) -> TextStyleRange? {
        guard limit > 0, start < limit, length > 0 else { return nil }
        let boundedStart = max(0, start)
        let boundedLength = min(length, limit - boundedStart)
        guard boundedLength > 0 else { return nil }
        return TextStyleRange(start: boundedStart, length: boundedLength, style: style)
    }
}

extension TextStyleRange {
    /// Converts to a Swift `Range<String.Index>` over `body`, or nil when the
    /// offsets do not land on character boundaries.
    public func range(in body: String) -> Range<String.Index>? {
        let utf16 = body.utf16
        guard
            let lower = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
            let upper = utf16.index(lower, offsetBy: length, limitedBy: utf16.endIndex),
            let lowerIndex = String.Index(lower, within: body),
            let upperIndex = String.Index(upper, within: body)
        else { return nil }
        return lowerIndex..<upperIndex
    }

    /// Builds a range from an `NSRange`, which is already in UTF-16 units.
    public init?(nsRange: NSRange, style: Style) {
        guard nsRange.location != NSNotFound, nsRange.length > 0 else { return nil }
        self.init(start: nsRange.location, length: nsRange.length, style: style)
    }

    public var nsRange: NSRange { NSRange(location: start, length: length) }
}

extension Array where Element == TextStyleRange {
    /// Normalises a set of ranges: drops empties, clamps to the body, and merges
    /// adjacent or overlapping runs of the same style so the wire form stays
    /// small and stable.
    public func normalized(forUTF16Length limit: Int) -> [TextStyleRange] {
        let clamped = compactMap { $0.clamped(toUTF16Length: limit) }
        var byStyle: [TextStyleRange.Style: [TextStyleRange]] = [:]
        for range in clamped {
            byStyle[range.style, default: []].append(range)
        }

        var merged: [TextStyleRange] = []
        for (style, ranges) in byStyle {
            var sorted = ranges.sorted { $0.start < $1.start }
            var current = sorted.removeFirst()
            for next in sorted {
                if next.start <= current.start + current.length {
                    let end = Swift.max(current.start + current.length, next.start + next.length)
                    current.length = end - current.start
                } else {
                    merged.append(current)
                    current = next
                }
            }
            merged.append(current)
            _ = style
        }
        return merged.sorted { ($0.start, $0.style.rawValue) < ($1.start, $1.style.rawValue) }
    }
}
