import LocalAuthentication

@MainActor
protocol AppAuthenticating {
    func unlock() async throws -> Bool
    func cancel()
}

@MainActor
final class AppLock: AppAuthenticating {
    private var context: LAContext?
    func unlock() async throws -> Bool {
        context?.invalidate()
        let context = LAContext()
        self.context = context
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? NSError(domain: LAError.errorDomain, code: LAError.passcodeNotSet.rawValue)
        }
        return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your private Volta vehicle history.")
    }
    func cancel() { context?.invalidate(); context = nil }
}
