// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/file;
import ballerina/lang.runtime;
import ballerina/sql;
import ballerina/test;
import ballerina/time;
import ballerinax/java.jdbc;

// Every database file created here uses the `test-` prefix that `stopSqliteServer` cleans up.
const string WAL_DB = "test-wal.db";
const string DEFAULT_MODE_DB = "test-default-mode.db";
const string BUSY_WAIT_DB = "test-busy-wait.db";
const string BUSY_FAIL_DB = "test-busy-fail.db";
const string SHARED_STORE_DB = "test-shared-store.db";
const string SEPARATE_STORES_DB = "test-separate-stores.db";
const string RESTART_DB = "test-restart.db";

// Opens a plain observer connection: it applies no options of its own, so whatever it reads
// back from `PRAGMA journal_mode` is what the store recorded in the database file.
isolated function newObserver(string dbFile) returns jdbc:Client|error =>
    new (url = "jdbc:sqlite:" + dbFile, connectionPool = {maxOpenConnections: 1, minIdleConnections: 1});

// Removes a scratch database and its sidecar files so that each test starts from nothing.
isolated function freshDatabaseFile(string dbFile) returns error? {
    foreach string suffix in ["", "-journal", "-wal", "-shm"] {
        string path = dbFile + suffix;
        if check file:test(path, file:EXISTS) {
            check file:remove(path);
        }
    }
}

// =====================================================================
// The session options must actually reach the connection
// =====================================================================

@test:Config {}
function testDriverPropertiesAreBuiltForEveryOption() {
    // Both options must survive together. They used to be issued as `connectionInitSql`
    // statements, of which the pool executes only the first, silently dropping the second.
    map<anydata> none = {};
    test:assertEquals(buildDriverProperties({}), none);
    test:assertEquals(buildDriverProperties({journalMode: "WAL"}), <map<anydata>>{"journal_mode": "WAL"});
    test:assertEquals(buildDriverProperties({busyTimeout: 2500}), <map<anydata>>{"busy_timeout": 2500});
    test:assertEquals(buildDriverProperties({journalMode: "WAL", busyTimeout: 2500}),
            <map<anydata>>{"journal_mode": "WAL", "busy_timeout": 2500});
}

@test:Config {}
function testBothPragmasAreReadBackFromTheConnection() returns error? {
    // The same properties the store passes must be observable as PRAGMA values on the
    // resulting connection. This is what would have caught the dropped-option bug.
    check freshDatabaseFile(WAL_DB);
    Options options = {journalMode: "WAL", busyTimeout: 7500};
    jdbc:Client cl = check new (url = "jdbc:sqlite:" + WAL_DB,
        options = {properties: buildDriverProperties(options)},
        connectionPool = {maxOpenConnections: 1, minIdleConnections: 1});

    string journalMode = check cl->queryRow(`PRAGMA journal_mode`);
    int busyTimeout = check cl->queryRow(`PRAGMA busy_timeout`);
    test:assertEquals(journalMode, "wal");
    test:assertEquals(busyTimeout, 7500);
    check cl.close();
}

@test:Config {}
function testWalJournalModeIsAppliedAndPersistedByTheStore() returns error? {
    // `WAL` is the mode that matters for concurrency and the one no other test exercises,
    // because it does not apply to an in-memory database. It is recorded in the database
    // file, so an independent connection must see it.
    check freshDatabaseFile(WAL_DB);
    ShortTermMemoryStore store = check new ({url: "jdbc:sqlite:" + WAL_DB, options: {journalMode: "WAL"}});
    check store.put(K1, [K1SM1, K1M1]);

    jdbc:Client observer = check newObserver(WAL_DB);
    string journalMode = check observer->queryRow(`PRAGMA journal_mode`);
    test:assertEquals(journalMode, "wal", "The store must have switched the database file to WAL");

    // The rows are visible to the observer too, so WAL did not cost visibility.
    int count = check observer->queryRow(`SELECT COUNT(*) FROM chat_messages WHERE message_key = ${K1}`);
    test:assertEquals(count, 2);
    check observer.close();
}

@test:Config {}
function testDefaultJournalModeIsDeleteForAFileDatabase() returns error? {
    // With no options set, the database is left at SQLite's file default, `DELETE`. The
    // doc comment on `Options` states this, so it is asserted rather than assumed.
    check freshDatabaseFile(DEFAULT_MODE_DB);
    ShortTermMemoryStore store = check new ({url: "jdbc:sqlite:" + DEFAULT_MODE_DB});
    check store.put(K1, K1M1);

    jdbc:Client observer = check newObserver(DEFAULT_MODE_DB);
    string journalMode = check observer->queryRow(`PRAGMA journal_mode`);
    test:assertEquals(journalMode, "delete");
    // The driver, not SQLite, supplies the default busy timeout, which is why `Options`
    // documents `3000` rather than SQLite's own `0`.
    int busyTimeout = check observer->queryRow(`PRAGMA busy_timeout`);
    test:assertEquals(busyTimeout, 3000);
    check observer.close();
}

@test:Config {}
function testJournalModeIsIgnoredForInMemoryDatabases() returns error? {
    // An in-memory database is always journalled in memory; the option cannot change that,
    // which is why `WAL` is excluded from `testInitWithEveryJournalMode`.
    jdbc:Client cl = check new (url = IN_MEMORY_URL,
        options = {properties: buildDriverProperties({journalMode: "WAL", busyTimeout: 1234})},
        connectionPool = {maxOpenConnections: 1, minIdleConnections: 1});
    string journalMode = check cl->queryRow(`PRAGMA journal_mode`);
    test:assertEquals(journalMode, "memory");

    // `busyTimeout`, unlike `journalMode`, does apply to an in-memory database.
    int busyTimeout = check cl->queryRow(`PRAGMA busy_timeout`);
    test:assertEquals(busyTimeout, 1234);
    check cl.close();
}

// =====================================================================
// `busyTimeout` under real lock contention
// =====================================================================

isolated function releaseAfter(jdbc:Client blocker, decimal seconds) returns error? {
    runtime:sleep(seconds);
    _ = check blocker->execute(`COMMIT`);
}

@test:Config {}
function testBusyTimeoutMakesTheStoreWaitForALockHolder() returns error? {
    // A generous `busyTimeout` must make a write wait for a competing writer instead of
    // failing, which is the whole reason the option exists.
    check freshDatabaseFile(BUSY_WAIT_DB);
    ShortTermMemoryStore store = check new ({
        url: "jdbc:sqlite:" + BUSY_WAIT_DB,
        options: {journalMode: "WAL", busyTimeout: 30000}
    });

    // A second, independent connection holds the write lock for a while.
    jdbc:Client blocker = check newObserver(BUSY_WAIT_DB);
    _ = check blocker->execute(`BEGIN EXCLUSIVE`);
    future<error?> release = start releaseAfter(blocker, 1);

    // The lock is released while this call is waiting on it, so the write must succeed.
    check store.put(K1, K1M1);
    check wait release;

    check assertInteractiveMessages(store, K1, [K1M1]);
    check blocker.close();
}

@test:Config {}
function testZeroBusyTimeoutFailsFastAndTheStoreRecovers() returns error? {
    // `busyTimeout: 0` is the documented "fail immediately" setting. The failure must be a
    // mapped `Error`, and the store must stay usable once the lock is gone.
    check freshDatabaseFile(BUSY_FAIL_DB);
    ShortTermMemoryStore store = check new ({
        url: "jdbc:sqlite:" + BUSY_FAIL_DB,
        options: {journalMode: "WAL", busyTimeout: 0}
    });
    check store.put(K1, K1M1);

    jdbc:Client blocker = check newObserver(BUSY_FAIL_DB);
    _ = check blocker->execute(`BEGIN EXCLUSIVE`);

    decimal startedAt = time:monotonicNow();
    Error? blocked = store.put(K1, k1m2);
    decimal elapsed = time:monotonicNow() - startedAt;
    if blocked is () {
        _ = check blocker->execute(`COMMIT`);
        test:assertFail("Expected the write to fail while another connection holds the write lock");
    }
    test:assertTrue(blocked.message().startsWith("Failed to add chat message: "),
            "Unexpected error message: " + blocked.message());

    // The timing is the assertion that `busyTimeout` reached the connection at all. Both
    // options are set here, and only one of them used to survive: when `busyTimeout` is
    // dropped, the driver's own default of 3000 ms applies and this write blocks for three
    // seconds instead of failing at once.
    test:assertTrue(elapsed < 2d,
            string `Expected 'busyTimeout: 0' to fail immediately, but the write blocked for ${elapsed}s`);

    // Reads do not need the write lock under WAL, so the store is not wedged.
    check assertInteractiveMessages(store, K1, [K1M1]);

    _ = check blocker->execute(`COMMIT`);
    check blocker.close();

    // With the lock released, the very same store must accept writes again.
    check store.put(K1, k1m2);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);
}

// =====================================================================
// Concurrency: write serialization is SQLite's defining characteristic
// =====================================================================

const int WORKERS = 4;
const int WRITES_PER_WORKER = 15;

isolated function putSequentially(ShortTermMemoryStore store, string key, int count) returns Error? {
    foreach int i in 0 ..< count {
        ai:ChatUserMessage message = {role: ai:USER, content: string `${key} message ${i}`};
        check store.put(key, message);
    }
}

@test:Config {}
function testConcurrentWritesThroughOneStore() returns error? {
    // Concurrent callers of a single store serialize on its pinned connection. Nothing may
    // be lost, and each key must keep its own messages in insertion order.
    check freshDatabaseFile(SHARED_STORE_DB);
    ShortTermMemoryStore store = check new ({
        url: "jdbc:sqlite:" + SHARED_STORE_DB,
        options: {journalMode: "WAL", busyTimeout: 30000}
    }, WORKERS * WRITES_PER_WORKER);

    future<Error?>[] pending = [];
    foreach int index in 0 ..< WORKERS {
        future<Error?> task = start putSequentially(store, string `worker-${index}`, WRITES_PER_WORKER);
        pending.push(task);
    }
    foreach future<Error?> task in pending {
        check wait task;
    }

    foreach int index in 0 ..< WORKERS {
        string key = string `worker-${index}`;
        ai:ChatInteractiveMessage[] stored = check store.getChatInteractiveMessages(key);
        test:assertEquals(stored.length(), WRITES_PER_WORKER, string `Lost writes for ${key}`);
        foreach int i in 0 ..< WRITES_PER_WORKER {
            ai:ChatInteractiveMessage message = stored[i];
            if message !is ai:ChatUserMessage {
                test:assertFail("Expected a user message");
            }
            test:assertEquals(message.content, string `${key} message ${i}`,
                    string `Out-of-order message for ${key}`);
        }
    }
}

@test:Config {}
function testConcurrentWritesFromSeparateStoresOverOneFile() returns error? {
    // Separate stores mean separate pools and therefore genuinely competing connections,
    // which is where SQLite's single-writer rule bites. WAL plus a generous `busyTimeout`
    // must be enough for every write to land.
    check freshDatabaseFile(SEPARATE_STORES_DB);
    DatabaseConfiguration config = {
        url: "jdbc:sqlite:" + SEPARATE_STORES_DB,
        options: {journalMode: "WAL", busyTimeout: 30000}
    };

    future<Error?>[] pending = [];
    foreach int index in 0 ..< WORKERS {
        ShortTermMemoryStore store = check new (config, WRITES_PER_WORKER);
        future<Error?> task = start putSequentially(store, string `store-${index}`, WRITES_PER_WORKER);
        pending.push(task);
    }
    foreach future<Error?> task in pending {
        check wait task;
    }

    jdbc:Client observer = check newObserver(SEPARATE_STORES_DB);
    int total = check observer->queryRow(`SELECT COUNT(*) FROM chat_messages`);
    test:assertEquals(total, WORKERS * WRITES_PER_WORKER, "Writes were lost across competing stores");
    foreach int index in 0 ..< WORKERS {
        string key = string `store-${index}`;
        int count = check observer->queryRow(
            `SELECT COUNT(*) FROM chat_messages WHERE message_key = ${key}`);
        test:assertEquals(count, WRITES_PER_WORKER, string `Lost writes for ${key}`);
    }
    check observer.close();
}

// =====================================================================
// Pre-existing tables the store did not create
// =====================================================================

// The store's `CREATE TABLE IF NOT EXISTS` is a no-op against an existing table of the same
// name, so a table with the wrong shape is only caught when the indexes are created.
final sql:ParameterizedQuery LEGACY_TABLE_DDL = `CREATE TABLE chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    message_key TEXT NOT NULL,
    message_role TEXT NOT NULL,
    message_json TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)`;

@test:Config {}
function testInitFailsWhenExistingTableHasIncompatibleColumns() returns error? {
    jdbc:Client cl = check newIsolatedClient();
    _ = check cl->execute(`CREATE TABLE chat_messages (id INTEGER PRIMARY KEY, payload TEXT)`);

    ShortTermMemoryStore|Error store = new (cl);
    if store is ShortTermMemoryStore {
        test:assertFail("Expected an error for a pre-existing table with an incompatible schema");
    }
    test:assertTrue(store.message().startsWith("Failed to create index on chat_messages"),
            "Unexpected error message: " + store.message());
    test:assertTrue(store.message().includes("message_key"),
            "The error must name the missing column: " + store.message());
    check cl.close();
}

@test:Config {}
function testInitFailsWhenExistingRowsViolateTheSystemMessageUniqueIndex() returns error? {
    // A table carrying two system messages for one key cannot take the partial unique index
    // that the system-message upsert depends on, so initialization must refuse it rather
    // than leave the store running without the invariant.
    jdbc:Client cl = check newIsolatedClient();
    _ = check cl->execute(LEGACY_TABLE_DDL);
    _ = check cl->batchExecute([
        `INSERT INTO chat_messages (message_key, message_role, message_json)
            VALUES (${K1}, 'system', ${K1SM1.toJsonString()})`,
        `INSERT INTO chat_messages (message_key, message_role, message_json)
            VALUES (${K1}, 'system', ${K1SM1.toJsonString()})`
    ]);

    ShortTermMemoryStore|Error store = new (cl);
    if store is ShortTermMemoryStore {
        test:assertFail("Expected an error when existing rows violate the unique index");
    }
    test:assertTrue(store.message().startsWith("Failed to create unique index on chat_messages"),
            "Unexpected error message: " + store.message());
    check cl.close();
}

@test:Config {}
function testInitAddsMissingIndexesToACompatibleExistingTable() returns error? {
    // A table created by an earlier version, without the indexes: initialization must add
    // both of them so that the system-message upsert has a conflict target to use.
    jdbc:Client cl = check newIsolatedClient();
    _ = check cl->execute(LEGACY_TABLE_DDL);

    ShortTermMemoryStore store = check new (cl);
    string indexes = check cl->queryRow(`SELECT group_concat(name) FROM sqlite_master
        WHERE type = 'index' AND tbl_name = 'chat_messages'`);
    test:assertTrue(indexes.includes("chat_messages_key_id_idx"), "Missing lookup index: " + indexes);
    test:assertTrue(indexes.includes("chat_messages_system_uidx"), "Missing unique index: " + indexes);

    // The upsert relies on the partial unique index, so a repeated system message must
    // replace the stored row rather than add one.
    ai:ChatSystemMessage replacement = {role: ai:SYSTEM, content: "You are a concise assistant."};
    check store.put(K1, K1SM1);
    check store.put(K1, replacement);
    int systemRows = check cl->queryRow(
        `SELECT COUNT(*) FROM chat_messages WHERE message_key = ${K1} AND message_role = 'system'`);
    test:assertEquals(systemRows, 1);
    check assertSystemMessage(store, K1, replacement);
    check cl.close();
}

// =====================================================================
// File-backed durability
// =====================================================================

@test:Config {}
function testMessagesSurviveAFullClientRestart() returns error? {
    // `testMessagesSurviveStoreRecreation` reuses one live client. This uses a second store
    // with its own client and pool, which is the closest a test gets to an application restart.
    check freshDatabaseFile(RESTART_DB);
    string url = "jdbc:sqlite:" + RESTART_DB;

    ShortTermMemoryStore before = check new ({url, options: {journalMode: "WAL"}}, 10);
    check before.put(K1, [K1SM1, K1M1, k1m2]);
    check before.put(K2, K2M1);

    ShortTermMemoryStore reopened = check new ({url, options: {journalMode: "WAL"}}, 10);
    check assertAllMessages(reopened, K1, [K1SM1, K1M1, k1m2]);
    check assertSystemMessage(reopened, K1, K1SM1);
    check assertInteractiveMessages(reopened, K2, [K2M1]);

    // Writes through the reopened store are visible to a third, independent connection.
    check reopened.put(K1, K1M3);
    jdbc:Client observer = check newObserver(RESTART_DB);
    int count = check observer->queryRow(
        `SELECT COUNT(*) FROM chat_messages WHERE message_key = ${K1}`);
    test:assertEquals(count, 4);
    check observer.close();
}
