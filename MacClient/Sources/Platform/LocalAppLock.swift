#if os(macOS)
    import Combine
    import Foundation
    import LocalAuthentication

    @MainActor
    final class LocalAppLock: ObservableObject {
        @Published private(set) var isAuthenticating = false
        @Published private(set) var lastError: String?

        var isAvailable: Bool {
            availability().available
        }

        var unavailableMessage: String? {
            let result = availability()
            return result.available ? nil : result.message
        }

        func authenticate(reason: String = "Unlock Vela") async -> Bool {
            guard !isAuthenticating else { return false }
            let context = LAContext()
            var availabilityError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
                lastError = Self.message(for: availabilityError, unavailable: true)
                return false
            }
            isAuthenticating = true
            defer { isAuthenticating = false }

            do {
                let result = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason
                )
                lastError = nil
                return result
            } catch {
                lastError = Self.message(for: error as NSError, unavailable: false)
                return false
            }
        }

        func clearError() {
            lastError = nil
        }

        private func availability() -> (available: Bool, message: String) {
            var error: NSError?
            let available = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
            return (available, Self.message(for: error, unavailable: true))
        }

        private static func message(for error: NSError?, unavailable: Bool) -> String {
            guard let error, error.domain == LAError.errorDomain,
                let code = LAError.Code(rawValue: error.code)
            else {
                return unavailable
                    ? "System authentication is unavailable on this Mac."
                    : "Authentication failed. Try again."
            }

            return switch code {
            case .userCancel, .appCancel, .systemCancel:
                "Authentication was cancelled."
            case .biometryLockout:
                "Touch ID is locked. Use your Mac login password."
            case .passcodeNotSet, .biometryNotAvailable, .notInteractive:
                "System authentication is unavailable. Check Login Password and Touch ID settings."
            default:
                unavailable
                    ? "System authentication is unavailable on this Mac."
                    : "Authentication failed. Try again."
            }
        }
    }
#endif
