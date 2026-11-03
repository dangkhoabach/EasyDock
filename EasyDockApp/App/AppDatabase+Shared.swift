import EasyDockCore

/// One connection for the app's lifetime. GRDB's `ValueObservation` only sees
/// writes made through the same `DatabaseQueue`, so every part of the app
/// goes through `shared`.
extension AppDatabase {
    /// Opened once, with the failure kept so launch can say so instead of
    /// running without saving anything.
    private static let opened = Result { try AppDatabase(path: AppDatabaseLocation.productionPath().path) }

    static var shared: AppDatabase? { try? opened.get() }

    static var openFailure: Error? {
        if case .failure(let error) = opened { return error }
        return nil
    }
}
