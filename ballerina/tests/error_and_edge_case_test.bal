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
import ballerina/sql;
import ballerina/test;
import ballerinax/java.jdbc;

// Every store below either reuses the suite-wide client or owns an isolated in-memory
// database. `newIsolatedClient` pins the pool to a single connection so that a
// `jdbc:sqlite::memory:` database stays coherent across operations, mirroring what the
// store itself does for connector-managed clients.
isolated function newIsolatedClient(string url = IN_MEMORY_URL) returns jdbc:Client|error =>
    new (url = url, connectionPool = {maxOpenConnections: 1, minIdleConnections: 1});

// =====================================================================
// Constructor argument validation
// =====================================================================

@test:Config {}
function testInitWithNonPositiveMaxMessagesPerKey() {
    foreach int invalid in [0, -1, -100] {
        ShortTermMemoryStore|Error store = new ({url: IN_MEMORY_URL}, invalid);
        if store is ShortTermMemoryStore {
            test:assertFail(string `Expected an error for 'maxMessagesPerKey': ${invalid}`);
        }
        test:assertTrue(store.message().includes(string `Invalid 'maxMessagesPerKey': ${invalid}`),
                "Unexpected error message: " + store.message());
        test:assertTrue(store.message().includes("must be a positive integer"),
                "Unexpected error message: " + store.message());
    }
}

@test:Config {}
function testInitWithSmallestValidMaxMessagesPerKey() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 1);
    test:assertEquals(store.getCapacity(), 1);

    test:assertFalse(check store.isFull(K1));
    check store.put(K1, K1M1);
    test:assertTrue(check store.isFull(K1));
}

@test:Config {}
function testInitWithValidTableNameVariants() returns error? {
    // Leading underscore, single letter, mixed case and digits are all permitted.
    foreach string name in ["_hidden", "T", "Chat_Messages_2", "a1"] {
        ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, tableName = name);
        check store.put(K1, K1SM1);
        check store.put(K1, K1M1);
        check assertAllMessages(store, K1, [K1SM1, K1M1]);
    }
}

@test:Config {}
function testInitWithInvalidUrlVariants() {
    foreach string url in ["", "sqlite:chat.db", "jdbc:mysql://localhost/chat", "JDBC:SQLITE:chat.db"] {
        ShortTermMemoryStore|Error store = new ({url});
        if store is ShortTermMemoryStore {
            test:assertFail(string `Expected an error for URL: '${url}'`);
        }
        test:assertTrue(store.message().includes("must start with 'jdbc:sqlite:'"),
                "Unexpected error message: " + store.message());
    }
}

// The table name is validated before the URL, so an invalid pair reports the table name.
@test:Config {}
function testTableNameIsValidatedBeforeUrl() {
    ShortTermMemoryStore|Error store = new ({url: "jdbc:mysql://localhost/chat"}, tableName = "bad-name");
    if store is ShortTermMemoryStore {
        test:assertFail("Expected an error for an invalid table name");
    }
    test:assertTrue(store.message().includes("Invalid table name"),
            "Unexpected error message: " + store.message());
}

// =====================================================================
// Connection option (`PRAGMA`) handling
// =====================================================================

@test:Config {}
function testInitWithOnlyJournalMode() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL, options: {journalMode: "MEMORY"}});
    check store.put(K1, K1M1);
    check assertInteractiveMessages(store, K1, [K1M1]);
}

@test:Config {}
function testInitWithOnlyBusyTimeout() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL, options: {busyTimeout: 2500}});
    check store.put(K1, K1M1);
    check assertInteractiveMessages(store, K1, [K1M1]);
}

@test:Config {}
function testInitWithEmptyOptions() returns error? {
    // No PRAGMA is issued; SQLite defaults apply.
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL, options: {}});
    check store.put(K1, K1M1);
    check assertInteractiveMessages(store, K1, [K1M1]);
}

@test:Config {}
function testInitWithEveryJournalMode() returns error? {
    // `WAL` is excluded: it is not applicable to an in-memory database.
    JournalMode[] modes = ["DELETE", "TRUNCATE", "PERSIST", "MEMORY", "OFF"];
    foreach JournalMode mode in modes {
        ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL, options: {journalMode: mode}});
        check store.put(K1, K1M1);
        check assertInteractiveMessages(store, K1, [K1M1]);
    }
}

// =====================================================================
// Initialization failures
// =====================================================================

@test:Config {}
function testInitFailsWhenDatabaseFileCannotBeOpened() {
    // The parent directory does not exist, so SQLite cannot create the database file.
    ShortTermMemoryStore|Error store = new ({url: "jdbc:sqlite:/no-such-directory-4f2a/chat.db"});
    if store is ShortTermMemoryStore {
        test:assertFail("Expected an error for an unopenable database file");
    }
    test:assertTrue(store.message().includes("Failed to create SQLite client")
            || store.message().includes("Failed to create chat_messages table"),
            "Unexpected error message: " + store.message());
}

@test:Config {}
function testInitFailsWhenDatabaseIsReadOnly() returns error? {
    // Seed a real database file, then reopen it read-only so that `CREATE TABLE` fails.
    // This is the only initialization failure that runs against a store-owned client, so
    // it also exercises the connection-pool cleanup on the failure path.
    string dbFile = "test-readonly.db";
    jdbc:Client seed = check new (url = "jdbc:sqlite:" + dbFile);
    _ = check seed->execute(`CREATE TABLE IF NOT EXISTS seeded (id INTEGER)`);
    check seed.close();

    ShortTermMemoryStore|Error store = new ({url: string `jdbc:sqlite:file:${dbFile}?mode=ro`});
    if store is ShortTermMemoryStore {
        test:assertFail("Expected an error for a read-only database");
    }
    test:assertTrue(store.message().includes("Failed to create chat_messages table")
            || store.message().includes("Failed to create SQLite client"),
            "Unexpected error message: " + store.message());
}

@test:Config {}
function testInitFailsWhenKeyIndexNameIsTaken() returns error? {
    // A table already occupies the name the store wants for its lookup index.
    jdbc:Client cl = check newIsolatedClient();
    _ = check cl->execute(`CREATE TABLE notes_key_id_idx (x INTEGER)`);

    ShortTermMemoryStore|Error store = new (cl, tableName = "notes");
    if store is ShortTermMemoryStore {
        test:assertFail("Expected an error when the index name is already taken");
    }
    test:assertTrue(store.message().includes("Failed to create index on notes"),
            "Unexpected error message: " + store.message());
    check cl.close();
}

@test:Config {}
function testInitFailsWhenSystemIndexNameIsTaken() returns error? {
    // A table already occupies the name the store wants for its unique system-message index.
    jdbc:Client cl = check newIsolatedClient();
    _ = check cl->execute(`CREATE TABLE notes_system_uidx (x INTEGER)`);

    ShortTermMemoryStore|Error store = new (cl, tableName = "notes");
    if store is ShortTermMemoryStore {
        test:assertFail("Expected an error when the unique index name is already taken");
    }
    test:assertTrue(store.message().includes("Failed to create unique index on notes"),
            "Unexpected error message: " + store.message());
    check cl.close();
}

@test:Config {}
function testInitIsIdempotentForTheSameTable() returns error? {
    // A second store over the same table must not fail on the `IF NOT EXISTS` DDL.
    jdbc:Client cl = check newIsolatedClient();
    ShortTermMemoryStore first = check new (cl);
    ShortTermMemoryStore second = check new (cl);

    check first.put(K1, K1M1);
    check assertInteractiveMessages(second, K1, [K1M1]);
    check cl.close();
}

// =====================================================================
// Operation failures against a broken database
// =====================================================================

// Dropping the table out from under a store makes every statement it issues fail with a
// genuine `sql:Error`, which is what the assertions below check the store maps correctly.
// (Closing the client is not usable here: the JDBC connector panics rather than returning
// an error when a closed client is used.)
isolated function newStoreWithMissingTable() returns [ShortTermMemoryStore, jdbc:Client]|error {
    jdbc:Client cl = check newIsolatedClient();
    ShortTermMemoryStore store = check new (cl, tableName = "vanishing");
    _ = check cl->execute(`DROP TABLE vanishing`);
    return [store, cl];
}

@test:Config {}
function testPutInteractiveMessageFailure() returns error? {
    var [store, cl] = check newStoreWithMissingTable();
    Error? result = store.put(K1, K1M1);
    if result is () {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to add chat message: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testPutSystemMessageFailure() returns error? {
    var [store, cl] = check newStoreWithMissingTable();
    Error? result = store.put(K1, K1SM1);
    if result is () {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to upsert system message: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testPutAllFailure() returns error? {
    var [store, cl] = check newStoreWithMissingTable();
    Error? result = store.put(K1, [K1M1, k1m2]);
    if result is () {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to add chat messages: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testPutAllWithSystemMessageFailure() returns error? {
    // The system message is upserted inside the same `do` block, so it reports the
    // batch-level message rather than the single-message one.
    var [store, cl] = check newStoreWithMissingTable();
    Error? result = store.put(K1, [K1SM1]);
    if result is () {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to add chat messages: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testGetChatSystemMessageFailure() returns error? {
    var [store, cl] = check newStoreWithMissingTable();
    ai:ChatSystemMessage|Error? result = store.getChatSystemMessage(K1);
    if result !is Error {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to retrieve system message: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testGetAllFailure() returns error? {
    var [store, cl] = check newStoreWithMissingTable();
    var result = store.getAll(K1);
    if result !is Error {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to retrieve chat messages: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testGetChatInteractiveMessagesFailure() returns error? {
    var [store, cl] = check newStoreWithMissingTable();
    ai:ChatInteractiveMessage[]|Error result = store.getChatInteractiveMessages(K1);
    if result !is Error {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to retrieve chat messages: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testRemoveChatSystemMessageFailure() returns error? {
    var [store, cl] = check newStoreWithMissingTable();
    Error? result = store.removeChatSystemMessage(K1);
    if result is () {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to delete existing system message: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testRemoveAllInteractiveMessagesFailure() returns error? {
    var [store, cl] = check newStoreWithMissingTable();
    Error? result = store.removeChatInteractiveMessages(K1);
    if result is () {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to delete chat messages: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testRemoveCountedInteractiveMessagesFailure() returns error? {
    // The counted branch issues a different statement from the uncounted one.
    var [store, cl] = check newStoreWithMissingTable();
    Error? result = store.removeChatInteractiveMessages(K1, 2);
    if result is () {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to delete chat messages: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testRemoveAllFailure() returns error? {
    var [store, cl] = check newStoreWithMissingTable();
    Error? result = store.removeAll(K1);
    if result is () {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to delete chat messages: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testIsFullFailure() returns error? {
    var [store, cl] = check newStoreWithMissingTable();
    boolean|Error result = store.isFull(K1);
    if result !is Error {
        test:assertFail("Expected an error when the backing table is missing");
    }
    test:assertTrue(result.message().startsWith("Failed to check if the memory store is full: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

// =====================================================================
// Malformed rows written outside the store
// =====================================================================

@test:Config {}
function testGetChatSystemMessageWithUnparsableRow() returns error? {
    jdbc:Client cl = check newIsolatedClient();
    ShortTermMemoryStore store = check new (cl);
    _ = check cl->execute(`INSERT INTO chat_messages (message_key, message_role, message_json)
        VALUES (${K1}, 'system', 'not json at all')`);

    ai:ChatSystemMessage|Error? result = store.getChatSystemMessage(K1);
    if result !is Error {
        test:assertFail("Expected a parse error for a malformed system message row");
    }
    test:assertTrue(result.message().startsWith("Failed to parse chat message from database: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testGetChatSystemMessageWithSchemaMismatchedRow() returns error? {
    // Valid JSON, but it does not conform to the stored-message shape.
    jdbc:Client cl = check newIsolatedClient();
    ShortTermMemoryStore store = check new (cl);
    _ = check cl->execute(`INSERT INTO chat_messages (message_key, message_role, message_json)
        VALUES (${K1}, 'system', '{"unexpected": true}')`);

    ai:ChatSystemMessage|Error? result = store.getChatSystemMessage(K1);
    if result !is Error {
        test:assertFail("Expected a parse error for a schema-mismatched system message row");
    }
    test:assertTrue(result.message().startsWith("Failed to parse chat message from database: "),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testGetAllWithUnparsableRow() returns error? {
    jdbc:Client cl = check newIsolatedClient();
    ShortTermMemoryStore store = check new (cl);
    check store.put(K1, K1M1);
    _ = check cl->execute(`INSERT INTO chat_messages (message_key, message_role, message_json)
        VALUES (${K1}, 'user', '{{ broken')`);

    var result = store.getAll(K1);
    if result !is Error {
        test:assertFail("Expected a parse error for a malformed interactive message row");
    }
    test:assertTrue(result.message().includes("Failed to parse chat message from database"),
            "Unexpected error message: " + result.message());
    check cl.close();
}

@test:Config {}
function testStoreRemainsUsableAfterUnparsableRow() returns error? {
    // A failed read must not leak the open result stream: the pool holds a single
    // connection, so a leaked stream would block every later operation until the
    // connection timeout elapses and leave the store permanently unusable.
    jdbc:Client cl = check newIsolatedClient();
    ShortTermMemoryStore store = check new (cl);
    check store.put(K1, K1M1);
    _ = check cl->execute(`INSERT INTO chat_messages (message_key, message_role, message_json)
        VALUES (${K1}, 'user', '{{ broken')`);

    var firstRead = store.getAll(K1);
    if firstRead !is Error {
        test:assertFail("Expected a parse error for a malformed interactive message row");
    }

    // The same failure must be reported again, promptly, rather than a pool timeout.
    var secondRead = store.getAll(K1);
    if secondRead !is Error {
        test:assertFail("Expected the parse error to repeat on the second read");
    }
    test:assertTrue(secondRead.message().includes("Failed to parse chat message from database"),
            "Unexpected error message: " + secondRead.message());

    // Writes and reads over an unaffected key must still work.
    check store.put(K2, K2M1);
    check assertAllMessages(store, K2, [K2M1]);

    // Removing the malformed row restores reads for the affected key.
    _ = check cl->execute(`DELETE FROM chat_messages WHERE message_json = '{{ broken'`);
    check assertAllMessages(store, K1, [K1M1]);
    check cl.close();
}

// =====================================================================
// `put` with an array of messages
// =====================================================================

@test:Config {}
function testPutWithEmptyArray() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    ai:ChatMessage[] none = [];

    check store.put(K1, none);

    check assertAllMessages(store, K1, []);
    check assertSystemMessage(store, K1, ());
    check assertInteractiveMessages(store, K1, []);
}

@test:Config {}
function testPutWithOnlyInteractiveMessagesInArray() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    check store.put(K1, [K1M1, k1m2, K1M3]);

    check assertSystemMessage(store, K1, ());
    check assertInteractiveMessages(store, K1, [K1M1, k1m2, K1M3]);
    check assertAllMessages(store, K1, [K1M1, k1m2, K1M3]);
}

@test:Config {}
function testPutWithOnlySystemMessagesInArray() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    ai:ChatSystemMessage second = {role: ai:SYSTEM, content: "You are a sports assistant."};
    ai:ChatSystemMessage third = {role: ai:SYSTEM, content: "You are a travel assistant."};

    check store.put(K1, [K1SM1, second, third]);

    // The last system message in the batch wins, and only one row is kept.
    check assertSystemMessage(store, K1, third);
    check assertInteractiveMessages(store, K1, []);
    check assertAllMessages(store, K1, [third]);
}

@test:Config {}
function testPutWithSingleElementArray() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    check store.put(K1, [K1M1]);
    check assertInteractiveMessages(store, K1, [K1M1]);
}

@test:Config {}
function testPutArrayPreservesOrderAcrossCalls() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 100);
    check store.put(K1, [K1M1, k1m2]);
    check store.put(K1, K1M3);
    check store.put(K1, [K1M4]);

    check assertInteractiveMessages(store, K1, [K1M1, k1m2, K1M3, K1M4]);
}

@test:Config {}
function testPutManyMessagesPreservesOrder() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 100);
    ai:ChatMessage[] batch = [];
    foreach int i in 0 ..< 50 {
        batch.push(<ai:ChatUserMessage>{role: ai:USER, content: string `message ${i}`});
    }
    check store.put(K1, batch);

    ai:ChatInteractiveMessage[] stored = check store.getChatInteractiveMessages(K1);
    test:assertEquals(stored.length(), 50);
    foreach int i in 0 ..< 50 {
        assertChatMessageEquals(stored[i], batch[i]);
    }
}

@test:Config {}
function testPutArrayWithSystemMessageInterleaved() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    check store.put(K1, [K1M1, K1SM1, k1m2]);

    // Regardless of its position in the batch, the system message is returned first.
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);
}

// =====================================================================
// Removal argument validation and no-op removals
// =====================================================================

@test:Config {}
function testRemoveInteractiveMessagesWithNonPositiveCount() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    check store.put(K1, K1M1);

    foreach int invalid in [0, -1, -25] {
        Error? result = store.removeChatInteractiveMessages(K1, invalid);
        if result is () {
            test:assertFail(string `Expected an error for 'count': ${invalid}`);
        }
        test:assertTrue(result.message().includes(string `Invalid 'count': ${invalid}`),
                "Unexpected error message: " + result.message());
        test:assertTrue(result.message().includes("must be nil or a positive integer"),
                "Unexpected error message: " + result.message());
    }

    // The rejected calls must not have removed anything.
    check assertInteractiveMessages(store, K1, [K1M1]);
}

@test:Config {}
function testRemoveExactCountOfInteractiveMessages() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    check store.put(K1, [K1SM1, K1M1, k1m2, K1M3]);

    check store.removeChatInteractiveMessages(K1, 3);

    check assertInteractiveMessages(store, K1, []);
    check assertSystemMessage(store, K1, K1SM1);
}

@test:Config {}
function testRemoveOneInteractiveMessageAtATime() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    check store.put(K1, [K1M1, k1m2, K1M3]);

    check store.removeChatInteractiveMessages(K1, 1);
    check assertInteractiveMessages(store, K1, [k1m2, K1M3]);

    check store.removeChatInteractiveMessages(K1, 1);
    check assertInteractiveMessages(store, K1, [K1M3]);
}

@test:Config {}
function testRemovalsOnUnknownKeyAreNoOps() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    check store.put(K1, [K1SM1, K1M1]);

    check store.removeAll(K3);
    check store.removeChatSystemMessage(K3);
    check store.removeChatInteractiveMessages(K3);
    check store.removeChatInteractiveMessages(K3, 5);

    // The untouched key is unaffected.
    check assertAllMessages(store, K1, [K1SM1, K1M1]);
}

@test:Config {}
function testRemoveSystemMessageWhenNoneIsStored() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    check store.put(K1, K1M1);

    check store.removeChatSystemMessage(K1);

    check assertSystemMessage(store, K1, ());
    check assertInteractiveMessages(store, K1, [K1M1]);
}

@test:Config {}
function testReadsOnUnknownKey() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    check store.put(K1, [K1SM1, K1M1]);

    check assertAllMessages(store, K3, []);
    check assertSystemMessage(store, K3, ());
    check assertInteractiveMessages(store, K3, []);
    test:assertFalse(check store.isFull(K3));
}

// =====================================================================
// Capacity boundaries
// =====================================================================

@test:Config {}
function testIsFullAtAndBeyondCapacity() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 2);
    check store.put(K1, [K1M1, k1m2]);
    test:assertTrue(check store.isFull(K1));

    // The store does not reject writes past the limit; the overflow handler is the
    // component that acts on `isFull`.
    check store.put(K1, K1M3);
    test:assertTrue(check store.isFull(K1));
    check assertInteractiveMessages(store, K1, [K1M1, k1m2, K1M3]);

    check store.removeChatInteractiveMessages(K1, 2);
    test:assertFalse(check store.isFull(K1));
}

@test:Config {}
function testIsFullIgnoresSystemMessageAndOtherKeys() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 2);
    check store.put(K1, [K1SM1, K1M1]);
    check store.put(K2, [K2M1, K1M3]);

    test:assertFalse(check store.isFull(K1));
    test:assertTrue(check store.isFull(K2));
}

// =====================================================================
// Isolation between stores, tables and keys
// =====================================================================

@test:Config {}
function testSeparateTablesAreIsolated() returns error? {
    jdbc:Client cl = check newIsolatedClient();
    ShortTermMemoryStore first = check new (cl, tableName = "history_one");
    ShortTermMemoryStore second = check new (cl, tableName = "history_two");

    check first.put(K1, [K1SM1, K1M1]);
    check second.put(K1, K2M1);

    check assertAllMessages(first, K1, [K1SM1, K1M1]);
    check assertAllMessages(second, K1, [K2M1]);

    check first.removeAll(K1);
    check assertAllMessages(first, K1, []);
    check assertAllMessages(second, K1, [K2M1]);
    check cl.close();
}

@test:Config {}
function testTwoStoresOverTheSameTableSeeEachOthersWrites() returns error? {
    jdbc:Client cl = check newIsolatedClient();
    ShortTermMemoryStore writer = check new (cl);
    ShortTermMemoryStore reader = check new (cl);

    check writer.put(K1, [K1SM1, K1M1]);
    check assertAllMessages(reader, K1, [K1SM1, K1M1]);

    check reader.removeChatInteractiveMessages(K1);
    check assertInteractiveMessages(writer, K1, []);
    check assertSystemMessage(writer, K1, K1SM1);
    check cl.close();
}

@test:Config {}
function testSystemMessagesAreScopedPerKey() returns error? {
    // The unique index covers `message_key`, so each key keeps its own system message.
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    ai:ChatSystemMessage k2System = {role: ai:SYSTEM, content: "You are a terse assistant."};

    check store.put(K1, K1SM1);
    check store.put(K2, k2System);

    check assertSystemMessage(store, K1, K1SM1);
    check assertSystemMessage(store, K2, k2System);

    check store.removeChatSystemMessage(K1);
    check assertSystemMessage(store, K1, ());
    check assertSystemMessage(store, K2, k2System);
}

// =====================================================================
// Content round-trips
// =====================================================================

@test:Config {}
function testUserMessageWithNameRoundTrip() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    ai:ChatUserMessage named = {role: ai:USER, content: "Hello", name: "alice"};

    check store.put(K1, named);

    ai:ChatInteractiveMessage[] stored = check store.getChatInteractiveMessages(K1);
    test:assertEquals(stored.length(), 1);
    assertChatMessageEquals(stored[0], named);
    ai:ChatInteractiveMessage first = stored[0];
    test:assertEquals(first is ai:ChatUserMessage ? first.name : (), "alice");
}

@test:Config {}
function testSystemMessageWithNameRoundTrip() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    ai:ChatSystemMessage named = {role: ai:SYSTEM, content: "Be brief.", name: "policy"};

    check store.put(K1, named);

    ai:ChatSystemMessage? stored = check store.getChatSystemMessage(K1);
    if stored is () {
        test:assertFail("Expected the stored system message");
    }
    assertChatMessageEquals(stored, named);
    test:assertEquals(stored.name, "policy");
}

@test:Config {}
function testEmptyStringContentRoundTrip() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    ai:ChatUserMessage empty = {role: ai:USER, content: ""};
    ai:ChatSystemMessage emptySystem = {role: ai:SYSTEM, content: ""};

    check store.put(K1, [emptySystem, empty]);

    check assertSystemMessage(store, K1, emptySystem);
    check assertInteractiveMessages(store, K1, [empty]);
}

@test:Config {}
function testSpecialCharacterContentRoundTrip() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 100);
    string[] contents = [
        "single ' quote",
        "double \" quote",
        "back\\slash",
        "line\nbreak\ttab",
        "unicode: 日本語 — ñ — 😀",
        "'); DROP TABLE chat_messages;--",
        "{\"looks\":\"like json\"}"
    ];

    ai:ChatMessage[] messages = from string content in contents
        select <ai:ChatUserMessage>{role: ai:USER, content};
    check store.put(K1, messages);

    ai:ChatInteractiveMessage[] stored = check store.getChatInteractiveMessages(K1);
    test:assertEquals(stored.length(), contents.length());
    foreach int i in 0 ..< contents.length() {
        assertChatMessageEquals(stored[i], messages[i]);
    }

    // The injection-shaped content must not have dropped the table.
    check store.put(K2, K2M1);
    check assertInteractiveMessages(store, K2, [K2M1]);
}

@test:Config {}
function testLargeContentRoundTrip() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    string large = "";
    foreach int _ in 0 ..< 2000 {
        large += "0123456789";
    }
    ai:ChatUserMessage message = {role: ai:USER, content: large};

    check store.put(K1, message);
    check assertInteractiveMessages(store, K1, [message]);
}

@test:Config {}
function testKeyWithSpecialCharacters() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    string[] keys = ["", "key with spaces", "key'with\"quotes", "键-🔑", "key;--"];

    foreach string key in keys {
        check store.put(key, [K1SM1, K1M1]);
        check assertAllMessages(store, key, [K1SM1, K1M1]);
    }

    foreach string key in keys {
        check store.removeAll(key);
        check assertAllMessages(store, key, []);
    }
}

@test:Config {}
function testPromptContentWithVariedInsertionTypes() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    int count = 42;
    float ratio = 0.75;
    boolean flag = true;
    string label = "Seattle";
    int[] values = [1, 2, 3];
    map<string> tags = {"unit": "celsius"};

    ai:Prompt prompt = `city=${label} count=${count} ratio=${ratio} flag=${flag} values=${values} tags=${tags}`;
    ai:ChatUserMessage message = {role: ai:USER, content: prompt};

    check store.put(K1, message);

    ai:ChatInteractiveMessage[] stored = check store.getChatInteractiveMessages(K1);
    test:assertEquals(stored.length(), 1);
    ai:ChatInteractiveMessage first = stored[0];
    if first !is ai:ChatUserMessage {
        test:assertFail("Expected a user message");
    }
    ai:Prompt|string content = first.content;
    if content is string {
        test:assertFail("Expected the prompt content to survive the round trip");
    }
    test:assertEquals(content.strings, prompt.strings);
    // Compared as JSON: the round trip returns immutable insertions, so the values match
    // while the static types (`readonly` vs not) do not.
    test:assertEquals(content.insertions.toJsonString(), prompt.insertions.toJsonString());
}

@test:Config {}
function testPromptWithNoInsertionsRoundTrip() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    ai:Prompt prompt = `A prompt with no insertions.`;
    ai:ChatSystemMessage message = {role: ai:SYSTEM, content: prompt};

    check store.put(K1, message);
    check assertSystemMessage(store, K1, message);
}

@test:Config {}
function testAssistantMessageVariantsRoundTrip() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 100);
    ai:ChatAssistantMessage contentOnly = {role: ai:ASSISTANT, content: "Plain reply"};
    ai:ChatAssistantMessage toolCallsOnly = {
        role: ai:ASSISTANT,
        content: (),
        toolCalls: [{name: "getWeather", arguments: {"city": "Seattle"}, id: "call_1"}]
    };
    ai:ChatAssistantMessage both = {
        role: ai:ASSISTANT,
        content: "Looking that up",
        name: "assistant-1",
        toolCalls: [{name: "getTime", arguments: (), id: "call_2"}]
    };
    ai:ChatAssistantMessage bare = {role: ai:ASSISTANT};

    check store.put(K1, [contentOnly, toolCallsOnly, both, bare]);
    check assertInteractiveMessages(store, K1, [contentOnly, toolCallsOnly, both, bare]);
}

@test:Config {}
function testFunctionMessageVariantsRoundTrip() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    ai:ChatFunctionMessage withId = {role: "function", name: "getWeather", content: "58F", id: "fn_1"};
    ai:ChatFunctionMessage withoutId = {role: "function", name: "getTime"};

    check store.put(K1, [withId, withoutId]);
    check assertInteractiveMessages(store, K1, [withId, withoutId]);
}

// =====================================================================
// Persistence across store instances
// =====================================================================

@test:Config {
    before: dropTable
}
function testMessagesSurviveStoreRecreation() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore first = check new (cl, 5);
    check first.put(K1, [K1SM1, K1M1, k1m2]);

    // A brand new store over the same table must observe everything already persisted.
    ShortTermMemoryStore second = check new (cl, 5);
    check assertAllMessages(second, K1, [K1SM1, K1M1, k1m2]);
    check assertSystemMessage(second, K1, K1SM1);
    check assertInteractiveMessages(second, K1, [K1M1, k1m2]);

    // Overwriting the system message through the new store keeps a single row.
    ai:ChatSystemMessage replacement = {role: ai:SYSTEM, content: "You are a concise assistant."};
    check second.put(K1, replacement);
    check assertFromDatabase(cl, K1, [replacement], SYSTEM);
}

// =====================================================================
// `sql:Error` surface checks
// =====================================================================

@test:Config {}
function testStoreErrorIsAMemoryError() {
    // The public error type must stay assignable to `ai:MemoryError` so that callers
    // handling memory failures generically keep working. The assignment below is the
    // assertion: it fails at compile time if the hierarchy ever changes.
    ShortTermMemoryStore|Error store = new ({url: "not-a-jdbc-url"});
    if store is ShortTermMemoryStore {
        test:assertFail("Expected an initialization error");
    }
    ai:MemoryError memoryError = store;
    test:assertTrue(memoryError.message().includes("must start with 'jdbc:sqlite:'"),
            "Unexpected error message: " + memoryError.message());
}

@test:Config {}
function testUnderlyingSqlErrorIsRetainedAsCause() returns error? {
    var [store, cl] = check newStoreWithMissingTable();
    Error? result = store.put(K1, K1M1);
    if result is () {
        test:assertFail("Expected an error when the backing table is missing");
    }
    error? cause = result.cause();
    if cause is () {
        test:assertFail("Expected the underlying sql:Error to be retained as the cause");
    }
    test:assertTrue(cause is sql:Error, "The cause must be the underlying sql:Error");
    check cl.close();
}
