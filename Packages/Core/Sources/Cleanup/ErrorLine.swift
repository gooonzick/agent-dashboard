import Foundation

/// The line of `stderr` that names the error (colima writes progress lines before it), or else the first line there
/// is. `nil` when `stderr` has no line at all.
func firstErrorLine(in stderr: String) -> String? {
    let lines = stderr.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
    let errorLine = lines.first { ["FATA", "ERRO", "Error", "error"].contains(where: $0.hasPrefix) }
    return (errorLine ?? lines.first).map(String.init)
}
