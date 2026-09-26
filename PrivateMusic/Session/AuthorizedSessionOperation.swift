import Foundation

extension SessionStore {
    /// Retries may rotate credentials, but must never cross a logout or an
    /// account switch. Also reject successful responses from the old account.
    func withAuthorizedToken<Value>(
        recoverSession: () async throws -> String,
        operation: (String) async throws -> Value
    ) async throws -> Value {
        let revision = accountRevision
        func checkAccount() throws {
            try Task.checkCancellation()
            guard accountRevision == revision, session != nil else {
                throw CancellationError()
            }
        }
        func invoke(_ token: String) async throws -> Value {
            try checkAccount()
            do {
                let value = try await operation(token)
                try checkAccount()
                return value
            } catch {
                try checkAccount()
                throw error
            }
        }
        func recoverWithinAccount() async throws -> String {
            try checkAccount()
            do {
                let token = try await recoverSession()
                try checkAccount()
                return token
            } catch {
                try checkAccount()
                throw error
            }
        }

        try Task.checkCancellation()
        guard var attemptedToken = accessToken else {
            throw APIError.unauthorized
        }
        if let session, session.shouldRefreshProactively, session.canRefresh {
            let refreshed = try? await recoverWithinAccount()
            if let refreshed {
                attemptedToken = refreshed
            }
            try checkAccount()
        }

        do {
            return try await invoke(attemptedToken)
        } catch let error as APIError where error == .unauthorized {
            try checkAccount()
        }

        if let latestToken = accessToken, latestToken != attemptedToken {
            do {
                return try await invoke(latestToken)
            } catch let error as APIError where error == .unauthorized {
                try checkAccount()
            }
        }
        let refreshedToken = try await recoverWithinAccount()
        return try await invoke(refreshedToken)
    }
}
