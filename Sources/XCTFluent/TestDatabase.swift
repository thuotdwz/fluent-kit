import FluentKit
import NIO

/// Lets you mock the row results for each query.
///
/// Make sure you `append` a result for each query you will
/// make to the database. Running out of results will result
/// in a failed `EventLoopFuture` with the
/// `TestDatabaseError.ranOutOfResults` error.
///
/// **Examples:**
///
/// Return an empty result for the next query:
///
///     let db = TestResultsDatabase()
///     db.append([])
///
/// Return an empty result for first query, and a single result
/// for the second query (perhaps a query to find a record with
/// no results followed by a successful query to create the record):
///
///     let db = TestResultsDatabase()
///     db.append([])
///     db.append([
///         TestOutput(["id": 1, "name": "Boise"])
///     ])
///
/// Return multiple rows for one query:
///
///     let db = TestResultsDatabase()
///     db.append([
///         TestOutput(["id": 1, ...]),
///         TestOutput(["id": 2, ...])
///     ])
public final class ArrayTestDatabase: TestDatabase {
    var results: [[DatabaseOutput]]

    public init() {
        self.results = []
    }

    public func append(_ result: [DatabaseOutput]) {
        self.results.append(result)
    }

    public func execute(query: DatabaseQuery, onOutput: (DatabaseOutput) -> ()) throws {
        guard !self.results.isEmpty else {
            throw TestDatabaseError.ranOutOfResults
        }
        for output in self.results.removeFirst() {
            onOutput(output)
        }
    }
}

public final class CallbackTestDatabase: TestDatabase {
    var callback: (DatabaseQuery) -> [DatabaseOutput]

    public init(callback: @escaping (DatabaseQuery) -> [DatabaseOutput]) {
        self.callback = callback
    }

    public func execute(query: DatabaseQuery, onOutput: (DatabaseOutput) -> ()) throws {
        for output in self.callback(query) {
            onOutput(output)
        }
    }
}

public protocol TestDatabase {
    func execute(
        query: DatabaseQuery,
        onOutput: (DatabaseOutput) -> ()
    ) throws
}

extension TestDatabase {
    public var db: Database {
        self.database(context: .init(
            configuration: self.configuration,
            logger: Logger(label: "codes.vapor.fluent.test"),
            eventLoop: EmbeddedEventLoop()
        ))
    }

    func database(context: DatabaseContext) -> Database {
        _TestDatabase(test: self, context: context)
    }
}

private struct _TestDatabase: Database {
    let test: TestDatabase
    var context: DatabaseContext

    func execute(
        query: DatabaseQuery,
        onOutput: @escaping (DatabaseOutput) -> ()
    ) -> EventLoopFuture<Void> {
        guard context.eventLoop.inEventLoop else {
            return self.eventLoop.flatSubmit {
                self.execute(query: query, onOutput: onOutput)
            }
        }
        do {
            try self.test.execute(query: query, onOutput: onOutput)
        } catch {
            return self.eventLoop.makeFailedFuture(error)
        }
        return self.eventLoop.makeSucceededFuture(())
    }

    func transaction<T>(_ closure: @escaping (Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        closure(self)
    }

    func withConnection<T>(_ closure: (Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        closure(self)
    }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> {
        self.eventLoop.makeSucceededFuture(())
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        self.eventLoop.makeSucceededFuture(())
    }
}

extension TestDatabase {
    public var configuration: DatabaseConfiguration {
        _TestConfiguration(test: self)
    }
}


private struct _TestConfiguration: DatabaseConfiguration {
    let test: TestDatabase
    var middleware: [AnyModelMiddleware] = []

    func makeDriver(for databases: Databases) -> DatabaseDriver {
        _TestDriver(test: self.test)
    }
}

private struct _TestDriver: DatabaseDriver {
    let test: TestDatabase

    func makeDatabase(with context: DatabaseContext) -> Database {
        self.test.database(context: context)
    }

    func shutdown() {
        // Do nothing
    }
}

public enum TestDatabaseError: Error {
    case ranOutOfResults
}

public struct TestOutput: DatabaseOutput {
    public func schema(_ schema: String) -> DatabaseOutput {
        self
    }

    public func decode<T>(_ path: [FieldKey], as type: T.Type) throws -> T
        where T: Decodable
    {
        if let res = dummyDecodedFields[path] as? T {
            return res
        }
        throw TestRowDecodeError.wrongType
    }

    public func contains(_ path: [FieldKey]) -> Bool {
        return true
    }

    public var description: String {
        return "<dummy>"
    }

    var dummyDecodedFields: [[FieldKey]: Any]

    public init() {
        self.dummyDecodedFields = [:]
    }

    public init(_ mockFields: [[FieldKey]: Any]) {
        self.dummyDecodedFields = mockFields
    }

    public init(_ mockFields: [FieldKey: Any]) {
        self.dummyDecodedFields = Dictionary(
            mockFields.map { (k, v) in ([k], v) },
            uniquingKeysWith: { $1 }
        )
    }

    public mutating func append(key: [FieldKey], value: Any) {
        dummyDecodedFields[key] = value
    }

    public mutating func append(key: FieldKey, value: Any) {
        dummyDecodedFields[[key]] = value
    }
}

public enum TestRowDecodeError: Error {
    case wrongType
}
