// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
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
// KIND, either express or implied. See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/cache;
import ballerina/lang.regexp;
import ballerina/sql;
import ballerinax/java.jdbc;

# Represents a distinct error type for memory store errors.
public type Error distinct ai:MemoryError;

type ExceedsSizeError distinct Error;

# Database configuration for the SQLite-backed memory store.
public type DatabaseConfiguration record {|
    # JDBC URL for the SQLite database (e.g., `jdbc:sqlite:./chat.db`,
    # `jdbc:sqlite::memory:`, or `jdbc:sqlite:./chat.db?cache=shared`).
    # Must start with `jdbc:sqlite:`.
    string url;
    # SQLite session-level options applied to each new connection.
    Options options = {};
    # Seconds to wait for a connection from the pool before failing.
    decimal connectionTimeout = 30.0;
|};

# SQLite session-level options applied to each new connection. Any field left
# unset falls back to SQLite's own default for that PRAGMA.
public type Options record {|
    # Journaling mode (`PRAGMA journal_mode`). When unset, SQLite's default (`DELETE`)
    # is used. Consider `WAL` for workloads that benefit from concurrent readers.
    JournalMode journalMode?;
    # Milliseconds SQLite waits when the database is locked before returning `SQLITE_BUSY`
    # (`PRAGMA busy_timeout`). When unset, SQLite's default (`0`, fail immediately) is used.
    # Set a positive value to give a competing writer time to release the lock.
    int busyTimeout?;
|};

# SQLite journaling mode (`PRAGMA journal_mode`).
public type JournalMode "DELETE"|"TRUNCATE"|"PERSIST"|"MEMORY"|"WAL"|"OFF";

type CachedMessages record {|
    readonly & ai:ChatSystemMessage systemMessage?;
    (readonly & ai:ChatInteractiveMessage)[] interactiveMessages;
|};

# Represents a SQLite-backed short-term memory store for messages.
public isolated class ShortTermMemoryStore {
    *ai:ShortTermMemoryStore;

    private final jdbc:Client dbClient;
    private final cache:Cache? cache;
    private final int maxMessagesPerKey;
    private final string tableName;
    // `true` only if the SQLite client was created internally by this store.
    private final boolean ownsDbClient;

    # Initializes the SQLite-backed short-term memory store.
    #
    # + dbClient - The SQLite JDBC client or database configuration to connect to the database
    # + maxMessagesPerKey - The maximum number of interactive messages to store per key (must be a
    # positive integer; default: 20)
    # + cacheConfig - The cache configuration for in-memory caching of messages (default: no caching)
    # + tableName - The name of the database table to store chat messages (default: "chat_messages").
    # Must start with a letter or underscore and contain only letters, digits, and underscores.
    # + return - An error if the initialization fails
    public isolated function init(jdbc:Client|DatabaseConfiguration dbClient,
            int maxMessagesPerKey = 20,
            cache:CacheConfig? cacheConfig = (),
            string tableName = "chat_messages") returns Error? {
        if !regexp:isFullMatch(re `^[A-Za-z_][A-Za-z0-9_]*$`, tableName) {
            return error(string `Invalid table name: '${tableName}'.`
                + " Table name must start with a letter or underscore, "
                + "and can only contain letters, digits, and underscores.");
        }
        if maxMessagesPerKey < 1 {
            return error(string `Invalid 'maxMessagesPerKey': ${maxMessagesPerKey}.`
                + " It must be a positive integer.");
        }
        self.tableName = tableName;
        if dbClient is jdbc:Client {
            self.dbClient = dbClient;
            self.ownsDbClient = false;
        } else {
            if !dbClient.url.startsWith("jdbc:sqlite:") {
                return error(string `Invalid 'url': '${dbClient.url}'.`
                    + " SQLite JDBC URLs must start with 'jdbc:sqlite:'.");
            }
            // SQLite is single-writer; the pool is pinned to one connection regardless of
            // the user-supplied config so the store cannot be misconfigured into SQLITE_BUSY,
            // and so `:memory:` databases (which are per-connection) remain coherent.
            sql:ConnectionPool pool = {
                maxOpenConnections: 1,
                minIdleConnections: 1,
                maxConnectionLifeTime: 0,
                connectionTimeout: dbClient.connectionTimeout,
                connectionInitSql: buildInitSqlStatements(dbClient.options)
            };
            jdbc:Client|sql:Error initializedClient = new jdbc:Client(
                url = dbClient.url,
                connectionPool = pool
            );
            if initializedClient is sql:Error {
                return error("Failed to create SQLite client: " + initializedClient.message(), initializedClient);
            }
            self.dbClient = initializedClient;
            self.ownsDbClient = true;
        }
        self.maxMessagesPerKey = maxMessagesPerKey;
        self.cache = cacheConfig is () ? () : new (cacheConfig);

        Error? initResult = self.initializeDatabase();
        if initResult is Error {
            // Avoid leaking the connection pool of an internally-created client on init failure.
            if self.ownsDbClient {
                sql:Error? closeResult = self.dbClient.close();
                if closeResult is sql:Error {
                    // Ignore: surface the original initialization error instead.
                }
            }
            return initResult;
        }
    }

    # Retrieves the system message, if it was provided, for a given key.
    #
    # + key - The key associated with the memory
    # + return - A copy of the message if it was specified, nil if it was not, or an
    # `Error` error if the operation fails
    public isolated function getChatSystemMessage(string key) returns ai:ChatSystemMessage|Error? {
        lock {
            CachedMessages? cacheEntry = self.getCacheEntry(key);
            if cacheEntry is CachedMessages {
                return cacheEntry.systemMessage;
            }
        }

        DatabaseRecord|sql:Error systemMessage = self.dbClient->queryRow(
            replaceTableNamePlaceholder(`
                SELECT message_json
                FROM $_tableName_$
                WHERE message_key = ${key} AND message_role = 'system'
                ORDER BY id ASC`,
                self.tableName
            )
        );

        if systemMessage is sql:NoRowsError {
            return ();
        }

        if systemMessage is sql:Error {
            return error("Failed to retrieve system message: " + systemMessage.message(), systemMessage);
        }

        ChatSystemMessageDatabaseMessage|error dbMessage = systemMessage.message_json.fromJsonStringWithType();
        if dbMessage is error {
            return error("Failed to parse chat message from database: " + dbMessage.message(), dbMessage);
        }

        // We intentionally don't populate the cache when just the system message is fetched
        // to avoid having to load interactive messages, which are generally significantly more in number, as well.
        return transformFromSystemMessageDatabaseMessage(dbMessage);
    }

    # Retrieves all stored interactive chat messages (i.e., all chat messages except the system
    # message) for a given key.
    #
    # + key - The key associated with the memory
    # + return - A copy of the messages, or an `Error` error if the operation fails
    public isolated function getChatInteractiveMessages(string key) returns ai:ChatInteractiveMessage[]|Error {
        lock {
            CachedMessages? cacheEntry = self.getCacheEntry(key);
            if cacheEntry is CachedMessages {
                return cacheEntry.interactiveMessages.clone();
            }
        }

        final var allMessages = check self.cacheFromDatabase(key);
        if allMessages is readonly & ai:ChatInteractiveMessage[] {
            return allMessages;
        }
        var [_, ...interactiveMessages] = allMessages;
        return interactiveMessages;
    }

    # Retrieves all stored chat messages for a given key.
    #
    # + key - The key associated with the memory
    # + return - A copy of the messages, or an `Error` error if the operation fails
    public isolated function getAll(string key)
            returns [ai:ChatSystemMessage, ai:ChatInteractiveMessage...]|ai:ChatInteractiveMessage[]|Error {
        lock {
            CachedMessages? cacheEntry = self.getCacheEntry(key);
            if cacheEntry is CachedMessages {
                final readonly & ai:ChatSystemMessage? systemMessage = cacheEntry.systemMessage;
                if systemMessage is ai:ChatSystemMessage {
                    return [systemMessage, ...cacheEntry.interactiveMessages].clone();
                }
                return cacheEntry.interactiveMessages.clone();
            }
        }

        return self.cacheFromDatabase(key);
    }

    # Adds one or more chat messages to the memory store for a given key.
    #
    # + key - The key associated with the memory
    # + message - The `ChatMessage` message or messages to store
    # + return - nil on success, or an `Error` if the operation fails
    public isolated function put(string key, ai:ChatMessage|ai:ChatMessage[] message) returns Error? {
        if message is ai:ChatMessage[] {
            return self.putAll(key, message);
        }
        ChatMessageDatabaseMessage dbMessage = transformToDatabaseMessage(message);
        if dbMessage is ChatSystemMessageDatabaseMessage {
            sql:ExecutionResult|sql:Error upsertResult = self.updateSystemMessage(key, dbMessage);
            if upsertResult is sql:Error {
                return error("Failed to upsert system message: " + upsertResult.message(), upsertResult);
            }
        } else {
            do {
                _ = check self.dbClient->execute(
                    replaceTableNamePlaceholder(`
                        INSERT INTO $_tableName_$ (message_key, message_role, message_json)
                        VALUES (${key}, ${dbMessage.role}, ${dbMessage.toJsonString()})`,
                        self.tableName
                    )
                );
            } on fail error err {
                return error("Failed to add chat message: " + err.message(), err);
            }
        }

        // The cache is updated in place after a successful write so it stays warm.
        final readonly & ai:ChatMessage immutableMessage = mapToImmutableMessage(message);
        lock {
            CachedMessages? cacheEntry = self.getCacheEntry(key);
            if cacheEntry is () {
                return;
            }
            if immutableMessage is ai:ChatSystemMessage {
                cacheEntry.systemMessage = immutableMessage;
            } else {
                cacheEntry.interactiveMessages.push(immutableMessage);
            }
        }
    }

    private isolated function putAll(string key, ai:ChatMessage[] messages) returns Error? {
        if messages.length() == 0 {
            return;
        }

        final var [newSystemMessages, newInteractiveMessages] = partitionMessagesByType(messages);
        final readonly & ai:ChatSystemMessage? finalChatSystemMessage = getLatestSystemMessage(newSystemMessages);
        final int incoming = newInteractiveMessages.length();
        if finalChatSystemMessage is () && incoming == 0 {
            return;
        }

        sql:ParameterizedQuery[] insertQueries = from ai:ChatInteractiveMessage msg in newInteractiveMessages
            let ChatMessageDatabaseMessage dbMsg = transformToDatabaseMessage(msg)
            select replaceTableNamePlaceholder(`
                    INSERT INTO $_tableName_$ (message_key, message_role, message_json)
                    VALUES (${key}, ${msg.role}, ${dbMsg.toJsonString()})`,
                    self.tableName
                );

        do {
            if finalChatSystemMessage is ai:ChatSystemMessage {
                _ = check self.updateSystemMessage(key, transformToDatabaseMessage(finalChatSystemMessage));
            }
            if insertQueries.length() > 0 {
                _ = check self.dbClient->batchExecute(insertQueries);
            }
        } on fail error err {
            return error("Failed to add chat messages: " + err.message(), err);
        }

        // The cache is updated in place after a successful write so it stays warm.
        final ai:ChatInteractiveMessage[] & readonly immutableInteractiveMessages =
            from ai:ChatInteractiveMessage msg in newInteractiveMessages
            select <readonly & ai:ChatInteractiveMessage>mapToImmutableMessage(msg);
        self.updateCache(key, finalChatSystemMessage, immutableInteractiveMessages);
    }

    private isolated function updateCache(string key, readonly & ai:ChatSystemMessage? systemMessage,
            readonly & ai:ChatInteractiveMessage[] interactiveMessages) {
        lock {
            CachedMessages? cacheEntry = self.getCacheEntry(key);
            if cacheEntry is () {
                return;
            }
            if systemMessage is ai:ChatSystemMessage {
                cacheEntry.systemMessage = systemMessage;
            }
            cacheEntry.interactiveMessages.push(...interactiveMessages);
        }
    }

    private isolated function updateSystemMessage(string key, ChatMessageDatabaseMessage systemMessage)
        returns sql:ExecutionResult|sql:Error {
        return self.dbClient->execute(
            replaceTableNamePlaceholder(`
                INSERT INTO $_tableName_$ (message_key, message_role, message_json)
                VALUES (${key}, ${systemMessage.role}, ${systemMessage.toJsonString()})
                ON CONFLICT (message_key) WHERE message_role = 'system'
                DO UPDATE SET message_json = excluded.message_json`,
                self.tableName
            )
        );
    }

    # Removes the system chat message, if specified, for a given key.
    #
    # + key - The key associated with the memory
    # + return - nil on success or if there is no system chat message against the key,
    # or an `Error` error if the operation fails
    public isolated function removeChatSystemMessage(string key) returns Error? {
        sql:ExecutionResult|sql:Error deleteResult = self.dbClient->execute(
            replaceTableNamePlaceholder(`
                DELETE FROM $_tableName_$
                WHERE message_key = ${key} AND message_role = 'system'`,
                self.tableName
            )
        );
        if deleteResult is sql:Error {
            self.removeCacheEntry(key);
            return error("Failed to delete existing system message: " + deleteResult.message(), deleteResult);
        }

        lock {
            CachedMessages? cacheEntry = self.getCacheEntry(key);
            if cacheEntry is CachedMessages && cacheEntry.hasKey("systemMessage") {
                cacheEntry.systemMessage = ();
            }
        }
    }

    # Removes all stored interactive chat messages (i.e., all chat messages except the system
    # message) for a given key.
    #
    # + key - The key associated with the memory
    # + count - Optional number of messages to remove, starting from the first interactive message;
    # if not provided, removes all messages
    # + return - nil on success, or an `Error` error if the operation fails
    public isolated function removeChatInteractiveMessages(string key, int? count = ()) returns Error? {
        if count is int && count <= 0 {
            return error(string `Invalid 'count': ${count}. It must be nil or a positive integer.`);
        }
        if count is () {
            sql:ExecutionResult|sql:Error result = self.dbClient->execute(
                replaceTableNamePlaceholder(`
                    DELETE FROM $_tableName_$
                    WHERE message_key = ${key} AND message_role != 'system'`,
                    self.tableName
                )
            );
            if result is sql:Error {
                self.removeCacheEntry(key);
                return error("Failed to delete chat messages: " + result.message(), result);
            }
        } else {
            sql:ExecutionResult|sql:Error result = self.dbClient->execute(
                replaceTableNamePlaceholder(`
                    DELETE FROM $_tableName_$
                    WHERE id IN (
                        SELECT id
                        FROM $_tableName_$
                        WHERE message_key = ${key} AND message_role != 'system'
                        ORDER BY id ASC
                        LIMIT ${count}
                    )`, self.tableName
                )
            );
            if result is sql:Error {
                self.removeCacheEntry(key);
                return error("Failed to delete chat messages: " + result.message(), result);
            }
        }

        lock {
            CachedMessages? cacheEntry = self.getCacheEntry(key);
            if cacheEntry is CachedMessages {
                ai:ChatInteractiveMessage[] interactiveMessages = cacheEntry.interactiveMessages;
                if count is () || count >= interactiveMessages.length() {
                    interactiveMessages.removeAll();
                } else {
                    foreach int i in 0 ..< count {
                        _ = interactiveMessages.shift();
                    }
                }
            }
        }
    }

    # Removes all stored chat messages for a given key.
    #
    # + key - The key associated with the memory
    # + return - nil on success, or an `Error` error if the operation fails
    public isolated function removeAll(string key) returns Error? {
        sql:ExecutionResult|sql:Error result = self.dbClient->execute(
            replaceTableNamePlaceholder(`
                DELETE FROM $_tableName_$
                WHERE message_key = ${key}`,
                self.tableName
            )
        );
        if result is sql:Error {
            self.removeCacheEntry(key);
            return error("Failed to delete chat messages: " + result.message(), result);
        }
        self.removeCacheEntry(key);
    }

    # Checks if the memory store is full for a given key.
    #
    # + key - The key associated with the memory
    # + return - true if the memory store is full, false otherwise, or an `Error` error if the operation fails
    public isolated function isFull(string key) returns boolean|Error {
        lock {
            CachedMessages? cacheEntry = self.getCacheEntry(key);
            if cacheEntry is CachedMessages {
                return cacheEntry.interactiveMessages.length() >= self.maxMessagesPerKey;
            }
        }

        // On a cache miss, only the count is needed, so use `COUNT(*)` rather than loading and
        // deserializing every stored message.
        int|sql:Error count = self.countInteractiveMessages(key);
        if count is sql:Error {
            return error("Failed to check if the memory store is full: " + count.message(), count);
        }
        return count >= self.maxMessagesPerKey;
    }

    private isolated function initializeDatabase() returns Error? {
        sql:ExecutionResult|sql:Error createTableResult = self.dbClient->execute(
            replaceTableNamePlaceholder(
                `CREATE TABLE IF NOT EXISTS $_tableName_$ (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    message_key TEXT NOT NULL,
                    message_role TEXT NOT NULL CHECK (message_role IN ('user', 'system', 'assistant', 'function')),
                    message_json TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                )`,
                self.tableName
            )
        );
        if createTableResult is sql:Error {
            return error(string `Failed to create ${self.tableName} table: ${createTableResult.message()}`,
                createTableResult);
        }

        sql:ExecutionResult|sql:Error createKeyIndexResult = self.dbClient->execute(
            replaceTableNamePlaceholder(
                `CREATE INDEX IF NOT EXISTS $_tableName_$_key_id_idx
                    ON $_tableName_$ (message_key, id)`,
                self.tableName
            )
        );
        if createKeyIndexResult is sql:Error {
            return error(string `Failed to create index on ${self.tableName}: ${createKeyIndexResult.message()}`,
                createKeyIndexResult);
        }

        sql:ExecutionResult|sql:Error createSystemIndexResult = self.dbClient->execute(
            replaceTableNamePlaceholder(
                `CREATE UNIQUE INDEX IF NOT EXISTS $_tableName_$_system_uidx
                    ON $_tableName_$ (message_key)
                    WHERE message_role = 'system'`,
                self.tableName
            )
        );
        if createSystemIndexResult is sql:Error {
            return error(string `Failed to create unique index on ${self.tableName}: ${createSystemIndexResult.message()}`,
                createSystemIndexResult);
        }
    }

    private isolated function cacheFromDatabase(string key)
            returns readonly & ([ai:ChatSystemMessage, ai:ChatInteractiveMessage...]|ai:ChatInteractiveMessage[])|Error {
        do {
            stream<DatabaseRecord, sql:Error?> messages = self.dbClient->query(
                replaceTableNamePlaceholder(`
                    SELECT message_json
                    FROM $_tableName_$
                    WHERE message_key = ${key}
                    ORDER BY id ASC`, self.tableName
                )
            );
            (ai:ChatSystemMessage & readonly)? systemMessage = ();
            (ai:ChatInteractiveMessage & readonly)[] interactiveMessages = [];

            check from DatabaseRecord {message_json} in messages
                do {
                    ChatMessageDatabaseMessage|error dbMessage = message_json.fromJsonStringWithType();
                    if dbMessage is error {
                        return error("Failed to parse chat message from database: " + dbMessage.message(), dbMessage);
                    }

                    if dbMessage is ChatSystemMessageDatabaseMessage {
                        systemMessage = transformFromSystemMessageDatabaseMessage(dbMessage);
                    } else {
                        interactiveMessages.push(transformFromInteractiveMessageDatabaseMessage(
                                <ChatInteractiveMessageDatabaseMessage>dbMessage));
                    }
                };

            final ai:ChatInteractiveMessage[] & readonly immutableInteractiveMessages = interactiveMessages.cloneReadOnly();
            lock {
                cache:Cache? cache = self.cache;
                // Caching is best-effort: a failure to populate the cache does not fail the read.
                if cache !is () && !cache.hasKey(key) {
                    cache:Error? cacheErr = cache.put(
                        key, <CachedMessages>{systemMessage, interactiveMessages: [...immutableInteractiveMessages]});
                    if cacheErr is cache:Error {
                        // Ignore: the read result is still returned to the caller.
                    }
                }
            }

            if systemMessage is () {
                return immutableInteractiveMessages;
            }
            return [systemMessage, ...interactiveMessages];
        } on fail error err {
            return error("Failed to retrieve chat messages: " + err.message(), err);
        }
    }

    private isolated function removeCacheEntry(string key) {
        lock {
            cache:Cache? cache = self.cache;
            if cache !is () && cache.hasKey(key) {
                cache:Error? err = cache.invalidate(key);
                if err is cache:Error {
                    // Ignore: the entry may already have been evicted.
                }
            }
        }
    }

    private isolated function getCacheEntry(string key) returns CachedMessages? {
        lock {
            cache:Cache? cache = self.cache;
            if cache is () || !cache.hasKey(key) {
                return ();
            }

            any|cache:Error cacheEntry = cache.get(key);
            if cacheEntry is cache:Error {
                return ();
            }

            // Since we have sole control over what is stored in the cache, this use of
            // `checkpanic` is safe.
            return checkpanic cacheEntry.ensureType();
        }
    }

    # Counts the interactive (non-system) messages currently stored for a given key.
    #
    # + key - The key associated with the memory
    # + return - The number of interactive messages, or an `sql:Error` if the query fails
    private isolated function countInteractiveMessages(string key) returns int|sql:Error {
        int count = check self.dbClient->queryRow(
            replaceTableNamePlaceholder(`
                SELECT COUNT(*)
                FROM $_tableName_$
                WHERE message_key = ${key} AND message_role != 'system'`,
                self.tableName
            )
        );
        return count;
    }

    # Retrieves the maximum number of interactive messages that can be stored for each key.
    #
    # + return - The configured capacity of the message store per key
    public isolated function getCapacity() returns int {
        return self.maxMessagesPerKey;
    }
}

isolated function replaceTableNamePlaceholder(sql:ParameterizedQuery query, string tableName) returns sql:ParameterizedQuery {
    final (string[] & readonly) strings = query.strings
        .'map(value => re `\$_tableName_\$`.replaceAll(value, tableName)).cloneReadOnly();
    query.strings = strings;
    return query;
}

isolated function partitionMessagesByType(ai:ChatMessage[] messages)
    returns [ai:ChatSystemMessage[], ai:ChatInteractiveMessage[]] {
    ai:ChatSystemMessage[] systemMsgs = [];
    ai:ChatInteractiveMessage[] interactiveMsgs = [];
    foreach ai:ChatMessage msg in messages {
        if msg is ai:ChatSystemMessage {
            systemMsgs.push(msg);
        } else if msg is ai:ChatInteractiveMessage {
            interactiveMsgs.push(msg);
        }
    }
    return [systemMsgs, interactiveMsgs];
}

isolated function getLatestSystemMessage(ai:ChatSystemMessage[] systemMessages)
    returns readonly & ai:ChatSystemMessage? {
    if systemMessages.length() == 0 {
        return;
    }
    ai:ChatSystemMessage lastSystemMessage = systemMessages[systemMessages.length() - 1];
    readonly & ai:ChatMessage immutableMessage = mapToImmutableMessage(lastSystemMessage);
    if immutableMessage is ai:ChatSystemMessage {
        return immutableMessage;
    }
    return;
}

// Builds the error returned when an insert would exceed the per-key message limit.
isolated function createExceedsSizeError(int maxMessagesPerKey, string key) returns ExceedsSizeError =>
    error ExceedsSizeError(string `Cannot add more messages.`
        + string ` Maximum limit '${maxMessagesPerKey}' exceeded for key '${key}'`);

isolated function buildInitSqlStatements(Options options) returns string[] {
    string[] statements = [];
    JournalMode? journalMode = options?.journalMode;
    if journalMode is JournalMode {
        statements.push(string `PRAGMA journal_mode = ${journalMode}`);
    }
    int? busyTimeout = options?.busyTimeout;
    if busyTimeout is int {
        statements.push(string `PRAGMA busy_timeout = ${busyTimeout}`);
    }
    return statements;
}
