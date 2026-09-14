import Foundation

enum RecordingState: Equatable {
    case idle
    case recording
}

struct MenuAvailability: Equatable {
    let canStart: Bool
    let canStop: Bool
}

extension RecordingState {
    var menuAvailability: MenuAvailability {
        switch self {
        case .idle:
            return MenuAvailability(canStart: true, canStop: false)
        case .recording:
            return MenuAvailability(canStart: false, canStop: true)
        }
    }
}

enum RecordingFileNamer {
    static func fileURL(in directory: URL, date: Date, title: String? = nil) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: date)
        var fileName = "Wiret-\(timestamp)"
        if let title {
            let sanitized = sanitizedTitle(title)
            if !sanitized.isEmpty {
                fileName += "-\(sanitized)"
            }
        }
        fileName += ".m4a"
        return directory.appendingPathComponent(fileName)
    }

    static func sanitizedTitle(_ title: String) -> String {
        let invalidCharacters: Set<Character> = ["/", ":", "\\", "?", "%", "*", "|", "\"", "<", ">"]
        let replaced = String(title.map { invalidCharacters.contains($0) ? "-" : $0 })

        var collapsedDashes = ""
        var lastWasDash = false
        for character in replaced {
            if character == "-" {
                if !lastWasDash {
                    collapsedDashes.append(character)
                }
                lastWasDash = true
            } else {
                collapsedDashes.append(character)
                lastWasDash = false
            }
        }

        let normalizedWhitespace = collapsedDashes
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let trimmed = normalizedWhitespace.trimmingCharacters(in: CharacterSet(charactersIn: "-").union(.whitespaces))
        if trimmed.count > 60 {
            return String(trimmed.prefix(60))
        }
        return trimmed
    }
}
