# Ballerina SQLite-backed short-term chat message store connector

[![Build](https://github.com/ballerina-platform/module-ballerinax-ai.sqlite/actions/workflows/ci.yml/badge.svg)](https://github.com/ballerina-platform/module-ballerinax-ai.sqlite/actions/workflows/ci.yml)
[![GitHub Last Commit](https://img.shields.io/github/last-commit/ballerina-platform/module-ballerinax-ai.sqlite.svg)](https://github.com/ballerina-platform/module-ballerinax-ai.sqlite/commits/main)
[![GitHub Issues](https://img.shields.io/github/issues/ballerina-platform/ballerina-library/module/ai.sqlite.svg?label=Open%20Issues)](https://github.com/ballerina-platform/ballerina-library/labels/module%2Fai.sqlite)

## Overview

This module provides a SQLite-backed short-term memory store to use with AI messages (e.g., with AI agents, model providers, etc.). SQLite runs in-process via the bundled JDBC driver, so there is no external service to set up.

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

    Optionally, specify the maximum number of interactive messages to keep per key (`maxMessagesPerKey` - defaults to `20`) and/or the table name (`tableName` - defaults to `"chat_messages"`).

    ```ballerina
    ai:ShortTermMemoryStore store = check new sqlite:ShortTermMemoryStore({url}, 10, "my_chat_messages");
    ```

> **Note on database URLs**: The connector uses `ballerinax/java.jdbc` under the hood. The `org.xerial:sqlite-jdbc` driver is already declared as a platform dependency of this module, so no additional JAR setup is required. Use `jdbc:sqlite:<path>` for a file-backed database or `jdbc:sqlite::memory:` for an in-process database.
>
> **Note on table naming**: The `tableName` argument is validated against `^[A-Za-z_][A-Za-z0-9_]*$` and inlined unquoted into SQL. SQLite preserves identifier case but compares identifiers case-insensitively, so casing in `tableName` is round-tripped but does not affect lookups.

## Configuration

When the store is created from a `DatabaseConfiguration` record rather than from an existing `jdbc:Client`, the following fields are available:

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `url` | `string` | *(required)* | JDBC URL for the database. Must start with `jdbc:sqlite:`. |
| `options.journalMode` | `sqlite:JournalMode` | *(unset)* | `PRAGMA journal_mode`. One of `DELETE`, `TRUNCATE`, `PERSIST`, `MEMORY`, `WAL`, `OFF`. |
| `options.busyTimeout` | `int` (milliseconds) | `3000`, from the driver | `PRAGMA busy_timeout`. |
| `connectionTimeout` | `decimal` (seconds) | `30.0` | How long a caller waits for the store's connection before failing. |

The `options` record is applied as `org.xerial:sqlite-jdbc` driver properties, so it takes effect on every connection the store opens.

- **`journalMode`** — `WAL` is recorded in the database file itself, so it persists for every later connection; it is the mode to choose when more than one connection or process uses the same file. The remaining modes apply per connection. A newly created file-backed database is at SQLite's default of `DELETE`. This option has no effect on a `jdbc:sqlite::memory:` database, whose journal mode is always `MEMORY`.
- **`busyTimeout`** — the number of milliseconds SQLite waits for a lock held by another connection before failing with `SQLITE_BUSY`. When left unset, the `sqlite-jdbc` driver applies `3000`; note that this is **not** SQLite's own default of `0`. Set `0` explicitly to fail immediately instead of waiting.

```ballerina
ai:ShortTermMemoryStore store = check new sqlite:ShortTermMemoryStore({
    url: "jdbc:sqlite:./chat_memory.db",
    options: {journalMode: "WAL", busyTimeout: 5000},
    connectionTimeout: 15
});
```

## Build from the source

### Setting up the prerequisites

1. Download and install Java SE Development Kit (JDK) version 21. You can download it from either of the following sources:

    * [Oracle JDK](https://www.oracle.com/java/technologies/downloads/)
    * [OpenJDK](https://adoptium.net/)

   > **Note:** After installation, remember to set the `JAVA_HOME` environment variable to the directory where JDK was installed.

2. Download and install [Ballerina Swan Lake](https://ballerina.io/).

3. Export Github Personal access token with read package permissions as follows,

    ```bash
    export packageUser=<Username>
    export packagePAT=<Personal access token>
    ```

### Build options

Execute the commands below to build from the source.

1. To build the package:

   ```bash
   ./gradlew clean build
   ```

2. To run the tests:

   ```bash
   ./gradlew clean test
   ```

3. To build without the tests:

   ```bash
   ./gradlew clean build -x test
   ```

4. To run tests against different environments:

   ```bash
   ./gradlew clean test -Pgroups=<Comma separated groups/test cases>
   ```

5. To debug the package with a remote debugger:

   ```bash
   ./gradlew clean build -Pdebug=<port>
   ```

6. To debug with the Ballerina language:

   ```bash
   ./gradlew clean build -PbalJavaDebug=<port>
   ```

7. Publish the generated artifacts to the local Ballerina Central repository:

    ```bash
    ./gradlew clean build -PpublishToLocalCentral=true
    ```

8. Publish the generated artifacts to the Ballerina Central repository:

   ```bash
   ./gradlew clean build -PpublishToCentral=true
   ```

## Contribute to Ballerina

As an open-source project, Ballerina welcomes contributions from the community.

For more information, go to the [contribution guidelines](https://github.com/ballerina-platform/ballerina-lang/blob/master/CONTRIBUTING.md).

## Code of conduct

All the contributors are encouraged to read the [Ballerina Code of Conduct](https://ballerina.io/code-of-conduct).

## Useful links

* For more information go to the [`ai.sqlite` package](https://central.ballerina.io/ballerinax/ai.sqlite/latest).
* For example demonstrations of the usage, go to [Ballerina By Examples](https://ballerina.io/learn/by-example/).
* Chat live with us via our [Discord server](https://discord.gg/ballerinalang).
* Post all technical questions on Stack Overflow with the [#ballerina](https://stackoverflow.com/questions/tagged/ballerina) tag.
