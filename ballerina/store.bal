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
import ballerina/lang.regexp;
import ballerina/sql;
import ballerinax/java.jdbc;

# Represents a distinct error type for memory store errors.
public type Error distinct ai:MemoryError;

# Database configuration for the SQLite-backed memory store.
public type DatabaseConfiguration record {|
    # JDBC URL for the SQLite database: `jdbc:sqlite:<path>` for a file-backed database
    # (e.g., `jdbc:sqlite:./chat.db`) or `jdbc:sqlite::memory:` for an in-process one.
    # Must start with `jdbc:sqlite:`.
    string url;
    # SQLite session-level options applied to every connection the store opens.
    Options options = {};
    # Seconds to wait for a connection from the pool before failing.
    decimal connectionTimeout = 30.0;
|};

# SQLite session-level options, applied as `sqlite-jdbc` driver properties to every
# connection the store opens. Any field left unset falls back to the driver's default.
public type Options record {|
    # Journaling mode (`PRAGMA journal_mode`). When unset, the database is left at its own
    # setting, which is `DELETE` for a newly created file-backed database. `WAL` is recorded
    # in the database file itself and so persists for every later connection, whereas the
    # other modes apply per connection. This option has no effect on a `jdbc:sqlite::memory:`
    # database, whose journal mode is always `MEMORY`.
    JournalMode journalMode?;
    # Milliseconds SQLite waits for a lock held by another connection before failing with
    # `SQLITE_BUSY` (`PRAGMA busy_timeout`). When unset, the `sqlite-jdbc` driver's default of
    # `3000` applies, which is not the same as SQLite's own default of `0`; set `0` explicitly
    # to fail immediately. Because the store pins its pool to a single connection, this only
    # affects contention with other connections or processes using the same database file.
    int busyTimeout?;
|};

# SQLite journaling mode (`PRAGMA journal_mode`).
public type JournalMode "DELETE"|"TRUNCATE"|"PERSIST"|"MEMORY"|"WAL"|"OFF";

# Represents a SQLite-backed short-term memory store for messages.
@display {label: "SQLite Short Term Memory Store"}
public isolated class ShortTermMemoryStore {
    *ai:ShortTermMemoryStore;

    private final jdbc:Client dbClient;
    private final int maxMessagesPerKey;
    private final string tableName;
    // `true` only if the SQLite client was created internally by this store.
    private final boolean ownsDbClient;

    # Initializes the SQLite-backed short-term memory store.
    #
    # + dbClient - The SQLite JDBC client or database configuration to connect to the database
    # + maxMessagesPerKey - The maximum number of interactive messages to store per key (must be a
    # positive integer; default: 20)
    # + tableName - The name of the database table to store chat messages (default: "chat_messages").
    # Must start with a letter or underscore and contain only letters, digits, and underscores.
    # + return - An error if the initialization fails
    public isolated function init(jdbc:Client|DatabaseConfiguration dbClient,
            int maxMessagesPerKey = 20,
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
                connectionTimeout: dbClient.connectionTimeout
            };
            jdbc:Client|sql:Error initializedClient = new jdbc:Client(
                url = dbClient.url,
                options = {properties: buildDriverProperties(dbClient.options)},
                connectionPool = pool
            );
            if initializedClient is sql:Error {
                return error("Failed to create SQLite client: " + initializedClient.message(), initializedClient);
            }
            self.dbClient = initializedClient;
            self.ownsDbClient = true;
        }
        self.maxMessagesPerKey = maxMessagesPerKey;

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

        return transformFromSystemMessageDatabaseMessage(dbMessage);
    }

    # Retrieves all stored interactive chat messages (i.e., all chat messages except the system
    # message) for a given key.
    #
    # + key - The key associated with the memory
    # + return - A copy of the messages, or an `Error` error if the operation fails
    public isolated function getChatInteractiveMessages(string key) returns ai:ChatInteractiveMessage[]|Error {
        final var allMessages = check self.loadFromDatabase(key);
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
        return self.loadFromDatabase(key);
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
    }

    private isolated function putAll(string key, ai:ChatMessage[] messages) returns Error? {
        final var [newSystemMessages, newInteractiveMessages] = partitionMessagesByType(messages);
        final ai:ChatSystemMessage? finalChatSystemMessage = getLatestSystemMessage(newSystemMessages);
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
            return error("Failed to delete existing system message: " + deleteResult.message(), deleteResult);
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
                return error("Failed to delete chat messages: " + result.message(), result);
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
            return error("Failed to delete chat messages: " + result.message(), result);
        }
    }

    # Checks if the memory store is full for a given key.
    #
    # + key - The key associated with the memory
    # + return - true if the memory store is full, false otherwise, or an `Error` error if the operation fails
    public isolated function isFull(string key) returns boolean|Error {
        // Only the count is needed, so use `COUNT(*)` rather than loading and
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

    private isolated function loadFromDatabase(string key)
            returns readonly & ([ai:ChatSystemMessage, ai:ChatInteractiveMessage...]|ai:ChatInteractiveMessage[])|Error {
        stream<DatabaseRecord, sql:Error?> messages = self.dbClient->query(
            replaceTableNamePlaceholder(`
                SELECT message_json
                FROM $_tableName_$
                WHERE message_key = ${key}
                ORDER BY id ASC`, self.tableName
            )
        );
        // The rows are collected before they are parsed: a `check`/`return` inside a query
        // `do` clause returns from this function outright, leaving the stream open. The
        // internally created pool holds a single connection, so a leaked stream would render
        // the store permanently unusable.
        string[]|sql:Error rawMessages = from DatabaseRecord {message_json} in messages
            select message_json;

        // Closing is idempotent, and covers the paths on which the query itself did not
        // drain the stream.
        sql:Error? closeResult = messages.close();

        if rawMessages is sql:Error {
            return error("Failed to retrieve chat messages: " + rawMessages.message(), rawMessages);
        }
        if closeResult is sql:Error {
            return error("Failed to retrieve chat messages: " + closeResult.message(), closeResult);
        }

        (ai:ChatSystemMessage & readonly)? systemMessage = ();
        (ai:ChatInteractiveMessage & readonly)[] interactiveMessages = [];

        foreach string rawMessage in rawMessages {
            ChatMessageDatabaseMessage|error dbMessage = rawMessage.fromJsonStringWithType();
            if dbMessage is error {
                return error("Failed to parse chat message from database: " + dbMessage.message(), dbMessage);
            }

            if dbMessage is ChatSystemMessageDatabaseMessage {
                systemMessage = transformFromSystemMessageDatabaseMessage(dbMessage);
            } else {
                interactiveMessages.push(transformFromInteractiveMessageDatabaseMessage(
                        <ChatInteractiveMessageDatabaseMessage>dbMessage));
            }
        }

        if systemMessage is () {
            return interactiveMessages.cloneReadOnly();
        }
        return [systemMessage, ...interactiveMessages];
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

// Returns the last system message, which is the one that wins when a single `put` call
// carries more than one.
isolated function getLatestSystemMessage(ai:ChatSystemMessage[] systemMessages) returns ai:ChatSystemMessage? {
    final int count = systemMessages.length();
    return count == 0 ? () : systemMessages[count - 1];
}

// The options are applied as `sqlite-jdbc` driver properties rather than through the pool's
// `connectionInitSql`, because only the first statement of that array is ever executed: with
// both options set, the second one would be dropped without any error. Driver properties are
// applied by the driver to every connection it opens, not just to the first one.
isolated function buildDriverProperties(Options options) returns map<anydata> {
    map<anydata> properties = {};
    JournalMode? journalMode = options?.journalMode;
    if journalMode is JournalMode {
        properties["journal_mode"] = journalMode;
    }
    int? busyTimeout = options?.busyTimeout;
    if busyTimeout is int {
        properties["busy_timeout"] = busyTimeout;
    }
    return properties;
}
