## Overview

This module provides a SQLite-backed short-term memory store to use with AI messages (e.g., with AI agents, model providers, etc.).

### Key Features

- SQLite-backed persistent storage for short-term AI message memory (file or in-memory database)
- Configurable per-key capacity (`maxMessagesPerKey`), reported through `isFull()` and `getCapacity()`; overflow is handled by `ai:ShortTermMemory` (trimming or summarization), not by the store
- Support for both direct database configuration and an existing `jdbc:Client`
- Zero external service dependencies — SQLite runs in-process via the bundled JDBC driver

## Prerequisites

- A writable filesystem location for the SQLite database file, or use of `jdbc:sqlite::memory:` for an in-process database.

## Quickstart

Follow the steps below to use this store in your Ballerina application:

1. Import the `ballerinax/ai.sqlite` module.

```ballerina
import ballerinax/ai.sqlite;
```

Optionally, import the `ballerina/ai` and/or `ballerinax/java.jdbc` module(s).

```ballerina
import ballerina/ai;
import ballerinax/java.jdbc;
```

2. Create the short-term memory store, by passing either the configuration for the database or a `jdbc:Client` client.

    i. Using the configuration

    ```ballerina
    import ballerina/ai;
    import ballerinax/ai.sqlite;

    configurable string url = "jdbc:sqlite:./chat_memory.db";

    ai:ShortTermMemoryStore store = check new sqlite:ShortTermMemoryStore({url});
    ```

    ii. Using a `jdbc:Client` client

    ```ballerina
    import ballerina/ai;
    import ballerinax/java.jdbc;
    import ballerinax/ai.sqlite as sqliteStore;

    configurable string url = "jdbc:sqlite:./chat_memory.db";

    jdbc:Client jdbcClient = check new (url);
    ai:ShortTermMemoryStore store = check new sqliteStore:ShortTermMemoryStore(jdbcClient);
    ```

    Optionally, specify the maximum number of messages to store per key (`maxMessagesPerKey` - defaults to `20`) and/or the table name (`tableName` - defaults to `"chat_messages"`).

    ```ballerina
    ai:ShortTermMemoryStore store = check new sqlite:ShortTermMemoryStore({url}, 10, "my_chat_messages");
    ```

> **Note on database URLs**: The connector uses `ballerinax/java.jdbc` under the hood. The `org.xerial:sqlite-jdbc` driver is already declared as a platform dependency of this module, so no additional JAR setup is required. Use `jdbc:sqlite:<path>` for a file-backed database or `jdbc:sqlite::memory:` for an in-process database.

> **Note on table naming**: The `tableName` argument is validated against `^[A-Za-z_][A-Za-z0-9_]*$` and inlined unquoted into SQL. SQLite preserves identifier case but compares identifiers case-insensitively, so casing in `tableName` is round-tripped but does not affect lookups.

## Schema

On initialization, the store creates the following objects in the connected database (using `CREATE … IF NOT EXISTS`, so it is safe to re-run):

```sql
CREATE TABLE chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    message_key TEXT NOT NULL,
    message_role TEXT NOT NULL CHECK (message_role IN ('user', 'system', 'assistant', 'function')),
    message_json TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX chat_messages_key_id_idx
    ON chat_messages (message_key, id);

CREATE UNIQUE INDEX chat_messages_system_uidx
    ON chat_messages (message_key) WHERE message_role = 'system';
```

The partial unique index enforces the "at most one system message per key" invariant and powers the upsert via `INSERT … ON CONFLICT … DO UPDATE`. Message ordering is by the monotonic `id` column (rather than `created_at`) because SQLite's `CURRENT_TIMESTAMP` has only one-second resolution, which is insufficient for rapid successive inserts.
