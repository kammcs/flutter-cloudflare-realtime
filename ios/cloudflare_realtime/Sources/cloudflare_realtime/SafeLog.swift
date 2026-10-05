import Foundation

/// An error's domain and code, for the unified log: never its description,
/// which can carry what an app or a push passed in (docs/design.md §4.9).
/// For example `com.apple.CallKit.error.requesttransaction 1`.
func logName(_ error: Error) -> String {
  let ns = error as NSError
  return "\(ns.domain) \(ns.code)"
}
