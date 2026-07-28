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
import ballerina/cache;
import ballerina/sql;
import ballerina/test;
import ballerinax/java.jdbc;

const string K1 = "key1";
const string K2 = "key2";
const string K3 = "key3";

const string TEST_DB_URL = "jdbc:sqlite:test-chat-memory.db";

const ai:ChatSystemMessage K1SM1 = {role: ai:SYSTEM, content: "You are a helpful assistant that is aware of the weather."};

const ai:ChatUserMessage K1M1 = {role: ai:USER, content: "Hello, my name is Alice. I'm from Seattle."};
final readonly & ai:ChatAssistantMessage k1m2 = {role: ai:ASSISTANT, content: "Hello Alice, what can I do for you?"};
const ai:ChatUserMessage K1M3 = {role: ai:USER, content: "I would like to know the weather today."};
final readonly & ai:ChatAssistantMessage K1M4 = {
    role: ai:ASSISTANT,
    content: "The weather in Seattle today is mostly cloudy with occasional showers and a high around 58°F."
};

const ai:ChatUserMessage K2M1 = {role: ai:USER, content: "Hello, my name is Bob."};

isolated jdbc:Client? modCl = ();

@test:BeforeSuite
function initClient() returns error? {
    lock {
        modCl = check new (url = TEST_DB_URL);
    }
}

function getClient() returns jdbc:Client {
    lock {
        return <jdbc:Client>modCl;
    }
}

function dropTable() returns error? {
    jdbc:Client cl = getClient();
    _ = check cl->execute(`DROP TABLE IF EXISTS chat_messages`);
}

@test:Config {
    before: dropTable
}
function testBasicStore() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);
    check store.put(K2, K2M1);

    check assertFromDatabase(cl, K1, [K1SM1], SYSTEM);
    check assertFromDatabase(cl, K1, [K1M1, k1m2], INTERACTIVE);
    check assertFromDatabase(cl, K1, [K1SM1, K1M1, k1m2]);

    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);
    check assertSystemMessage(store, K1, K1SM1);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);

    check assertFromDatabase(cl, K2, [], SYSTEM);
    check assertFromDatabase(cl, K2, [K2M1], INTERACTIVE);
    check assertFromDatabase(cl, K2, [K2M1]);

    check assertAllMessages(store, K2, [K2M1]);
    check assertSystemMessage(store, K2, ());
    check assertInteractiveMessages(store, K2, [K2M1]);

    check store.removeAll(K1);

    check assertFromDatabase(cl, K1, [], SYSTEM);
    check assertFromDatabase(cl, K1, [], INTERACTIVE);
    check assertFromDatabase(cl, K1, []);

    check assertAllMessages(store, K1, []);
    check assertSystemMessage(store, K1, ());
    check assertInteractiveMessages(store, K1, []);

    check assertFromDatabase(cl, K2, [], SYSTEM);
    check assertFromDatabase(cl, K2, [K2M1], INTERACTIVE);
    check assertFromDatabase(cl, K2, [K2M1]);

    check assertAllMessages(store, K2, [K2M1]);
    check assertSystemMessage(store, K2, ());
    check assertInteractiveMessages(store, K2, [K2M1]);

    // Add more messages to K1 after deletion.
    check store.put(K1, K1M3);

    check assertFromDatabase(cl, K1, [], SYSTEM);
    check assertFromDatabase(cl, K1, [K1M3], INTERACTIVE);
    check assertFromDatabase(cl, K1, [K1M3]);

    check assertAllMessages(store, K1, [K1M3]);
    check assertSystemMessage(store, K1, ());
    check assertInteractiveMessages(store, K1, [K1M3]);
}

@test:Config {
    before: dropTable
}
function testRemoveSystemMessage() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);
    check store.put(K2, K2M1);

    check store.removeChatSystemMessage(K1);

    check assertFromDatabase(cl, K1, [], SYSTEM);
    check assertFromDatabase(cl, K1, [K1M1, k1m2], INTERACTIVE);
    check assertFromDatabase(cl, K1, [K1M1, k1m2]);

    check assertAllMessages(store, K1, [K1M1, k1m2]);
    check assertSystemMessage(store, K1, ());
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);

    check assertFromDatabase(cl, K2, [], SYSTEM);
    check assertFromDatabase(cl, K2, [K2M1], INTERACTIVE);
    check assertFromDatabase(cl, K2, [K2M1]);

    check assertAllMessages(store, K2, [K2M1]);
    check assertSystemMessage(store, K2, ());
    check assertInteractiveMessages(store, K2, [K2M1]);

    check store.removeChatSystemMessage(K2);

    check assertFromDatabase(cl, K2, [], SYSTEM);
    check assertFromDatabase(cl, K2, [K2M1], INTERACTIVE);
    check assertFromDatabase(cl, K2, [K2M1]);

    check assertAllMessages(store, K2, [K2M1]);
    check assertSystemMessage(store, K2, ());
    check assertInteractiveMessages(store, K2, [K2M1]);
}

@test:Config {
    before: dropTable
}
function testRemoveInteractiveMessages() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);
    check store.put(K2, K2M1);

    check store.removeChatInteractiveMessages(K1);

    check assertFromDatabase(cl, K1, [K1SM1], SYSTEM);
    check assertFromDatabase(cl, K1, [], INTERACTIVE);
    check assertFromDatabase(cl, K1, [K1SM1]);

    check assertAllMessages(store, K1, [K1SM1]);
    check assertSystemMessage(store, K1, K1SM1);
    check assertInteractiveMessages(store, K1, []);

    check assertFromDatabase(cl, K2, [], SYSTEM);
    check assertFromDatabase(cl, K2, [K2M1], INTERACTIVE);
    check assertFromDatabase(cl, K2, [K2M1]);

    check assertAllMessages(store, K2, [K2M1]);
    check assertSystemMessage(store, K2, ());
    check assertInteractiveMessages(store, K2, [K2M1]);

    check store.removeChatInteractiveMessages(K2);

    check assertFromDatabase(cl, K1, [K1SM1], SYSTEM);
    check assertFromDatabase(cl, K1, [], INTERACTIVE);
    check assertFromDatabase(cl, K1, [K1SM1]);

    check assertAllMessages(store, K1, [K1SM1]);
    check assertSystemMessage(store, K1, K1SM1);
    check assertInteractiveMessages(store, K1, []);

    check assertFromDatabase(cl, K2, [], SYSTEM);
    check assertFromDatabase(cl, K2, [], INTERACTIVE);
    check assertFromDatabase(cl, K2, []);

    check assertAllMessages(store, K2, []);
    check assertSystemMessage(store, K2, ());
    check assertInteractiveMessages(store, K2, []);
}

@test:Config {
    before: dropTable
}
function testRemoveAllMessages() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);
    check store.put(K2, K2M1);

    check store.removeAll(K1);

    check assertFromDatabase(cl, K1, [], SYSTEM);
    check assertFromDatabase(cl, K1, [], INTERACTIVE);
    check assertFromDatabase(cl, K1, []);

    check assertAllMessages(store, K1, []);
    check assertSystemMessage(store, K1, ());
    check assertInteractiveMessages(store, K1, []);

    check assertFromDatabase(cl, K2, [], SYSTEM);
    check assertFromDatabase(cl, K2, [K2M1], INTERACTIVE);
    check assertFromDatabase(cl, K2, [K2M1]);

    check assertAllMessages(store, K2, [K2M1]);
    check assertSystemMessage(store, K2, ());
    check assertInteractiveMessages(store, K2, [K2M1]);

    check store.removeAll(K2);

    check assertFromDatabase(cl, K1, [], SYSTEM);
    check assertFromDatabase(cl, K1, [], INTERACTIVE);
    check assertFromDatabase(cl, K1, []);

    check assertAllMessages(store, K1, []);
    check assertSystemMessage(store, K1, ());
    check assertInteractiveMessages(store, K1, []);

    check assertFromDatabase(cl, K2, [], SYSTEM);
    check assertFromDatabase(cl, K2, [], INTERACTIVE);
    check assertFromDatabase(cl, K2, []);

    check assertAllMessages(store, K2, []);
    check assertSystemMessage(store, K2, ());
    check assertInteractiveMessages(store, K2, []);
}

@test:Config {
    before: dropTable
}
function testRemovingSubsetOfInteractiveMessages() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);
    check store.put(K1, K1M3);
    check store.put(K1, K1M4);

    check store.removeChatInteractiveMessages(K1, 2);

    check assertFromDatabase(cl, K1, [K1SM1], SYSTEM);
    check assertFromDatabase(cl, K1, [K1M3, K1M4], INTERACTIVE);
    check assertFromDatabase(cl, K1, [K1SM1, K1M3, K1M4]);

    check assertSystemMessage(store, K1, K1SM1);
    check assertInteractiveMessages(store, K1, [K1M3, K1M4]);
    check assertAllMessages(store, K1, [K1SM1, K1M3, K1M4]);
}

@test:Config {
    before: dropTable
}
function testSystemMessageOverwrite() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);

    check assertSystemMessage(store, K1, K1SM1);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);

    check assertFromDatabase(cl, K1, [K1SM1], SYSTEM);
    check assertFromDatabase(cl, K1, [K1M1, k1m2], INTERACTIVE);
    check assertFromDatabase(cl, K1, [K1SM1, K1M1, k1m2]);

    final readonly & ai:ChatSystemMessage k1sm2 = {
        role: ai:SYSTEM,
        content: "You are a helpful assistant that is aware of sports."
    };
    check store.put(K1, k1sm2);

    check assertSystemMessage(store, K1, k1sm2);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);
    check assertAllMessages(store, K1, [k1sm2, K1M1, k1m2]);

    check assertFromDatabase(cl, K1, [k1sm2], SYSTEM);
    check assertFromDatabase(cl, K1, [K1M1, k1m2], INTERACTIVE);
    check assertFromDatabase(cl, K1, [k1sm2, K1M1, k1m2]);

    stream<DatabaseRecord, error?> fromDb = cl->query(
        `SELECT message_json FROM chat_messages WHERE message_key = ${K1} AND message_role = 'system'`);
    DatabaseRecord[] records = check from DatabaseRecord dbRecord in fromDb
        select dbRecord;
    test:assertEquals(records.length(), 1);
    ChatSystemMessageDatabaseMessage dbSystemMessage = check records[0].message_json.fromJsonStringWithType();
    assertChatMessageEquals(transformFromSystemMessageDatabaseMessage(dbSystemMessage), k1sm2);
}

@test:Config {
    before: dropTable
}
function testSystemMessageOverwriteWithPutAll() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    final readonly & ai:ChatSystemMessage k1sm2 = {
        role: ai:SYSTEM,
        content: "You are a helpful assistant that is aware of sports."
    };
    check store.put(K1, [K1SM1, K1M1, k1m2, k1sm2]);
    check assertSystemMessage(store, K1, k1sm2);
    check assertFromDatabase(cl, K1, [k1sm2, K1M1, k1m2]);

    stream<DatabaseRecord, error?> fromDb = cl->query(
        `SELECT message_json FROM chat_messages WHERE message_key = ${K1} AND message_role = 'system'`);
    DatabaseRecord[] records = check from DatabaseRecord dbRecord in fromDb
        select dbRecord;
    test:assertEquals(records.length(), 1);
    ChatSystemMessageDatabaseMessage dbSystemMessage = check records[0].message_json.fromJsonStringWithType();
    assertChatMessageEquals(transformFromSystemMessageDatabaseMessage(dbSystemMessage), k1sm2);
}

@test:Config {
    before: dropTable
}
function testPutWithDifferentMessageKinds() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl);

    final readonly & ai:ChatFunctionMessage funcMessage = {
        role: "function",
        name: "getWeather",
        id: "func1"
    };

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);
    check store.put(K1, funcMessage);

    check assertFromDatabase(cl, K1, [K1SM1], SYSTEM);
    check assertFromDatabase(cl, K1, [K1M1, k1m2, funcMessage], INTERACTIVE);
    check assertFromDatabase(cl, K1, [K1SM1, K1M1, k1m2, funcMessage]);

    check assertSystemMessage(store, K1, K1SM1);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2, funcMessage]);
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2, funcMessage]);
}

@test:Config {
    before: dropTable
}
function testUpdateWithSystemMessageWhenInteractiveMessagesPresentInDbOnStart() returns error? {
    jdbc:Client cl = getClient();
    ShortTermMemoryStore store = check new (cl, 5);

    _ = check cl->batchExecute([
        `INSERT INTO chat_messages (message_key, message_role, message_json) VALUES
        (${K1}, ${K1M1.role}, ${K1M1.toJsonString()})`,
        `INSERT INTO chat_messages (message_key, message_role, message_json) VALUES
        (${K1}, ${k1m2.role}, ${k1m2.toJsonString()})`
    ]);

    check store.put(K1, K1SM1);

    check assertFromDatabase(cl, K1, [K1SM1], SYSTEM);
    check assertFromDatabase(cl, K1, [K1M1, k1m2], INTERACTIVE);
    check assertFromDatabase(cl, K1, [K1M1, k1m2, K1SM1]);

    check assertSystemMessage(store, K1, K1SM1);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);
}

function assertAllMessages(ShortTermMemoryStore store, string key, ai:ChatMessage[] expected) returns error? {
    ai:ChatMessage[] actual = check store.getAll(key);
    int actualLength = actual.length();
    test:assertEquals(actualLength, expected.length());
    foreach var index in 0 ..< actualLength {
        assertChatMessageEquals(actual[index], expected[index]);
    }
}

function assertSystemMessage(ShortTermMemoryStore store, string key, ai:ChatSystemMessage? expected) returns error? {
    ai:ChatSystemMessage? actual = check store.getChatSystemMessage(key);
    if expected is () && actual is () {
        return;
    }

    if expected is () || actual is () {
        test:assertFail("Actual and expected ChatSystemMessage do not match");
    }

    assertChatMessageEquals(actual, expected);
}

function assertInteractiveMessages(ShortTermMemoryStore store, string key, ai:ChatInteractiveMessage[] expected) returns error? {
    ai:ChatInteractiveMessage[] actual = check store.getChatInteractiveMessages(key);
    int actualLength = actual.length();
    test:assertEquals(actualLength, expected.length());
    foreach var index in 0 ..< actualLength {
        assertChatMessageEquals(actual[index], expected[index]);
    }
}

enum MessageType {
    SYSTEM,
    INTERACTIVE,
    ALL
}

function assertFromDatabase(jdbc:Client cl, string key, ai:ChatMessage[] expected, MessageType messageType = ALL) returns error? {
    sql:ParameterizedQuery[] selectQuery = [`SELECT message_json FROM chat_messages WHERE message_key = ${key}`];
    if messageType == SYSTEM {
        selectQuery.push(` AND message_role = 'system'`);
    } else if messageType == INTERACTIVE {
        selectQuery.push(` AND message_role != 'system'`);
    }
    selectQuery.push(` ORDER BY id ASC`);
    stream<DatabaseRecord, error?> databaseRecords = cl->query(sql:queryConcat(...selectQuery));
    ai:ChatMessage[] actualMessages = check toChatMessages(databaseRecords);
    int actualLength = actualMessages.length();
    test:assertEquals(actualLength, expected.length());
    foreach var index in 0 ..< actualLength {
        assertChatMessageEquals(actualMessages[index], expected[index]);
    }
}

function toChatMessages(stream<DatabaseRecord, error?> databaseRecords) returns ai:ChatMessage[]|error =>
    from DatabaseRecord databaseRecord in databaseRecords
select transformFromDatabaseMessage(check toChatMessage(databaseRecord));

function toChatMessage(DatabaseRecord databaseRecord) returns ChatMessageDatabaseMessage|error =>
    databaseRecord.message_json.fromJsonStringWithType();

isolated function assertChatMessageEquals(ai:ChatMessage actual, ai:ChatMessage expected) {
    if (actual is ai:ChatUserMessage && expected is ai:ChatUserMessage) ||
            (actual is ai:ChatSystemMessage && expected is ai:ChatSystemMessage) {
        test:assertEquals(actual.role, expected.role);
        assertContentEquals(actual.content, expected.content);
        test:assertEquals(actual.name, expected.name);
        return;
    }

    if actual is ai:ChatFunctionMessage && expected is ai:ChatFunctionMessage {
        test:assertEquals(actual.role, expected.role);
        test:assertEquals(actual.name, expected.name);
        test:assertEquals(actual.id, expected.id);
        return;
    }

    if actual is ai:ChatAssistantMessage && expected is ai:ChatAssistantMessage {
        test:assertEquals(actual.role, expected.role);
        test:assertEquals(actual.name, expected.name);
        test:assertEquals(actual.toolCalls, expected.toolCalls);
        return;
    }

    test:assertFail("Actual and expected ChatMessage types do not match");
}

isolated function assertContentEquals(ai:Prompt|string actual, ai:Prompt|string expected) {
    if actual is string && expected is string {
        test:assertEquals(actual, expected);
        return;
    }

    if actual is ai:Prompt && expected is ai:Prompt {
        test:assertEquals(actual.strings, expected.strings);
        test:assertEquals(actual.insertions, expected.insertions);
        return;
    }

    test:assertFail("Actual and expected content do not match");
}

@test:Config {
    before: dropTable
}
function testBasicStoreWithCache() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);
    check store.put(K2, K2M1);

    // First retrieval - should load from database and cache
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);

    // Second retrieval - should use cache (verify by checking results still match)
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);

    check assertAllMessages(store, K2, [K2M1]);
    check assertInteractiveMessages(store, K2, [K2M1]);
}

@test:Config {
    before: dropTable
}
function testBasicStoreWithCacheWithPutAll() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, [K1SM1, K1M1, k1m2]);
    check store.put(K2, K2M1);

    // First retrieval - should load from database and cache
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);

    // Second retrieval - should use cache (verify by checking results still match)
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);

    check assertAllMessages(store, K2, [K2M1]);
    check assertInteractiveMessages(store, K2, [K2M1]);
}

@test:Config {
    before: dropTable
}
function testCacheUpdateOnPut() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);

    // Load into cache
    check assertAllMessages(store, K1, [K1SM1, K1M1]);

    // Add more messages - cache should be updated
    check store.put(K1, k1m2);
    check store.put(K1, K1M3);

    // Verify cache reflects the updates
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2, K1M3]);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2, K1M3]);
}

@test:Config {
    before: dropTable
}
function testCacheUpdateWithPutAll() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, [K1SM1, K1M1]);
    check assertAllMessages(store, K1, [K1SM1, K1M1]);

    // Add more messages - cache should be updated
    check store.put(K1, [k1m2, K1M3]);

    // Verify cache reflects the updates
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2, K1M3]);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2, K1M3]);
}

@test:Config {
    before: dropTable
}
function testCacheSystemMessageUpdate() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);

    // Load into cache
    check assertSystemMessage(store, K1, K1SM1);
    check assertAllMessages(store, K1, [K1SM1, K1M1]);

    // Update system message
    final readonly & ai:ChatSystemMessage k1sm2 = {
        role: ai:SYSTEM,
        content: "You are a helpful assistant that is aware of sports."
    };
    check store.put(K1, k1sm2);

    // Verify cache reflects the system message update
    check assertSystemMessage(store, K1, k1sm2);
    check assertAllMessages(store, K1, [k1sm2, K1M1]);
}

@test:Config {
    before: dropTable
}
function testCacheSystemMessageUpdateOnPutAll() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, [K1SM1, K1M1]);

    // Load into cache
    check assertSystemMessage(store, K1, K1SM1);
    check assertAllMessages(store, K1, [K1SM1, K1M1]);

    // Update system message
    final readonly & ai:ChatSystemMessage k1sm2 = {
        role: ai:SYSTEM,
        content: "You are a helpful assistant that is aware of sports."
    };
    check store.put(K1, [k1sm2, k1m2]);

    // Verify cache reflects the system message update
    check assertSystemMessage(store, K1, k1sm2);
    check assertAllMessages(store, K1, [k1sm2, K1M1, k1m2]);
}

@test:Config {
    before: dropTable
}
function testCacheInvalidationOnRemoveAll() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);

    // Load into cache
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);

    // Remove all messages
    check store.removeAll(K1);

    // Verify cache is invalidated and returns empty
    check assertAllMessages(store, K1, []);
    check assertSystemMessage(store, K1, ());
    check assertInteractiveMessages(store, K1, []);
}

@test:Config {
    before: dropTable
}
function testCacheInvalidationOnRemoveInteractiveMessages() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);
    check store.put(K1, K1M3);

    // Load into cache
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2, K1M3]);

    // Remove all interactive messages
    check store.removeChatInteractiveMessages(K1);

    // Verify cache reflects the removal
    check assertAllMessages(store, K1, [K1SM1]);
    check assertSystemMessage(store, K1, K1SM1);
    check assertInteractiveMessages(store, K1, []);
}

@test:Config {
    before: dropTable
}
function testCacheInvalidationOnRemoveSubsetOfInteractiveMessages() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);
    check store.put(K1, K1M3);
    check store.put(K1, K1M4);

    // Load into cache
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2, K1M3, K1M4]);

    // Remove first 2 interactive messages
    check store.removeChatInteractiveMessages(K1, 2);

    // Verify cache reflects the partial removal
    check assertAllMessages(store, K1, [K1SM1, K1M3, K1M4]);
    check assertInteractiveMessages(store, K1, [K1M3, K1M4]);
}

@test:Config {
    before: dropTable
}
function testCacheUpdateOnRemoveSystemMessage() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);

    // Load into cache
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);
    check assertSystemMessage(store, K1, K1SM1);

    // Remove system message
    check store.removeChatSystemMessage(K1);

    // Verify cache reflects the system message removal
    check assertAllMessages(store, K1, [K1M1, k1m2]);
    check assertSystemMessage(store, K1, ());
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);
}

@test:Config {
    before: dropTable
}
function testCacheWithMultipleKeys() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    // Add messages for K1
    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);

    // Add messages for K2
    check store.put(K2, K2M1);

    // Load both into cache
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);
    check assertAllMessages(store, K2, [K2M1]);

    // Remove K1
    check store.removeAll(K1);

    // Verify K1 is cleared but K2 is still in cache
    check assertAllMessages(store, K1, []);
    check assertAllMessages(store, K2, [K2M1]);
}

@test:Config {
    before: dropTable
}
function testCacheWithSmallCapacity() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 2,
        evictionFactor: 0.5
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, K1M1);
    check store.put(K2, K2M1);
    check store.put(K3, K1M3);

    // Load K1 and K2 into cache
    check assertAllMessages(store, K1, [K1M1]);
    check assertAllMessages(store, K2, [K2M1]);

    // Load K3 - may evict older entries due to capacity
    check assertAllMessages(store, K3, [K1M3]);

    // All keys should still be retrievable (from cache or database)
    check assertAllMessages(store, K1, [K1M1]);
    check assertAllMessages(store, K2, [K2M1]);
    check assertAllMessages(store, K3, [K1M3]);
}

@test:Config {
    before: dropTable
}
function testSystemMessageRetrievalDoesNotPopulateCache() returns error? {
    jdbc:Client cl = getClient();
    cache:CacheConfig cacheConfig = {
        capacity: 10,
        evictionFactor: 0.2
    };
    ShortTermMemoryStore store = check new (cl, cacheConfig = cacheConfig);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);

    // Retrieve only system message - should NOT populate cache
    check assertSystemMessage(store, K1, K1SM1);

    // Add more messages
    check store.put(K1, K1M3);

    // Retrieve all messages - should load from database and include K1M3
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2, K1M3]);
}

// =====================================================================
// Initialization / configuration parameter tests
// =====================================================================

// Each store created from a `DatabaseConfiguration` below uses `jdbc:sqlite::memory:`.
// This exercises the connector-managed connection pool and gives each test a fully
// isolated database with no scratch files to clean up.
const string IN_MEMORY_URL = "jdbc:sqlite::memory:";

@test:Config {}
function testInitWithInMemoryDatabaseConfiguration() returns error? {
    // Multiple operations must observe the same in-memory database. This only holds
    // because the connector pins the pool to a single connection.
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);

    check assertSystemMessage(store, K1, K1SM1);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);
    check assertAllMessages(store, K1, [K1SM1, K1M1, k1m2]);

    check store.removeAll(K1);
    check assertAllMessages(store, K1, []);
}

@test:Config {}
function testInitWithMinimalDatabaseConfiguration() returns error? {
    // Only the mandatory `url` field is set; everything else uses defaults.
    DatabaseConfiguration dbConfig = {url: IN_MEMORY_URL};
    ShortTermMemoryStore store = check new (dbConfig);
    check store.put(K1, K1M1);
    check assertInteractiveMessages(store, K1, [K1M1]);
}

@test:Config {}
function testInitWithCustomConnectionTimeout() returns error? {
    // A caller-supplied connection timeout must be honoured.
    DatabaseConfiguration dbConfig = {url: IN_MEMORY_URL, connectionTimeout: 45};
    ShortTermMemoryStore store = check new (dbConfig);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);
    check assertInteractiveMessages(store, K1, [K1M1, k1m2]);
}

@test:Config {}
function testInitWithCustomOptions() returns error? {
    // A caller-supplied options record must be applied to the connection.
    DatabaseConfiguration dbConfig = {
        url: IN_MEMORY_URL,
        options: {
            journalMode: "MEMORY",
            busyTimeout: 1000
        }
    };
    ShortTermMemoryStore store = check new (dbConfig);
    check store.put(K1, K1M1);
    check assertInteractiveMessages(store, K1, [K1M1]);
}

@test:Config {}
function testInitWithInvalidJdbcUrl() {
    DatabaseConfiguration dbConfig = {url: "jdbc:postgresql://localhost/foo"};
    ShortTermMemoryStore|Error store = new (dbConfig);
    if store is ShortTermMemoryStore {
        test:assertFail("Expected an error for a non-SQLite JDBC URL");
    }
    test:assertTrue(store.message().includes("must start with 'jdbc:sqlite:'"),
        "Unexpected error message: " + store.message());
}

@test:Config {}
function testInitWithFullConfiguration() returns error? {
    cache:CacheConfig cacheConfig = {capacity: 10, evictionFactor: 0.2};
    DatabaseConfiguration dbConfig = {url: IN_MEMORY_URL, connectionTimeout: 30};
    ShortTermMemoryStore store = check new (dbConfig, 15, cacheConfig, "custom_messages");

    test:assertEquals(store.getCapacity(), 15);

    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check assertAllMessages(store, K1, [K1SM1, K1M1]);
}

@test:Config {}
function testInitWithCustomTableName() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, tableName = "agent_chat_history");
    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    check assertAllMessages(store, K1, [K1SM1, K1M1]);
}

@test:Config {}
function testInitWithInvalidTableName() {
    string[] invalidNames = ["1table", "table-name", "table name", "table;drop", "",
        "table.name", "robert'); DROP TABLE students;--"];
    foreach string name in invalidNames {
        ShortTermMemoryStore|Error store = new ({url: IN_MEMORY_URL}, tableName = name);
        if store is ShortTermMemoryStore {
            test:assertFail(string `Expected an error for invalid table name: '${name}'`);
        } else {
            test:assertTrue(store.message().includes("Invalid table name"),
                "Unexpected error message: " + store.message());
        }
    }
}

@test:Config {}
function testInitWithCacheConfiguration() returns error? {
    cache:CacheConfig cacheConfig = {capacity: 5, evictionFactor: 0.25};
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, cacheConfig = cacheConfig);
    check store.put(K1, K1SM1);
    check store.put(K1, K1M1);
    // First read loads from DB and populates the cache; second read is served from cache.
    check assertAllMessages(store, K1, [K1SM1, K1M1]);
    check assertAllMessages(store, K1, [K1SM1, K1M1]);
}

// =====================================================================
// Capacity / fullness API tests
// =====================================================================

@test:Config {}
function testGetCapacity() returns error? {
    ShortTermMemoryStore defaultStore = check new ({url: IN_MEMORY_URL});
    test:assertEquals(defaultStore.getCapacity(), 20);

    ShortTermMemoryStore customStore = check new ({url: IN_MEMORY_URL}, 7);
    test:assertEquals(customStore.getCapacity(), 7);
}

@test:Config {}
function testIsFull() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 3);

    test:assertFalse(check store.isFull(K1));
    check store.put(K1, K1M1);
    test:assertFalse(check store.isFull(K1));
    check store.put(K1, k1m2);
    test:assertFalse(check store.isFull(K1));
    check store.put(K1, K1M3);
    test:assertTrue(check store.isFull(K1));

    // A system message must not count towards fullness.
    check store.put(K2, K1SM1);
    test:assertFalse(check store.isFull(K2));
}

// =====================================================================
// Overflow / message-limit enforcement tests
// =====================================================================

@test:Config {}
function testRemoveInteractiveMessagesCountExceedingAvailable() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 5);
    check store.put(K1, K1M1);
    check store.put(K1, k1m2);

    // A removal count larger than the stored count removes everything available.
    check store.removeChatInteractiveMessages(K1, 10);
    check assertInteractiveMessages(store, K1, []);

    // Capacity is freed up again after the removal.
    check store.put(K1, K1M3);
    check assertInteractiveMessages(store, K1, [K1M3]);
}

// =====================================================================
// Message-content round-trip tests
// =====================================================================

@test:Config {}
function testPromptContentRoundTrip() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});

    string city = "Seattle";
    int day = 3;
    ai:Prompt userPrompt = `What is the weather in ${city} on day ${day}?`;
    ai:ChatUserMessage userMsg = {role: ai:USER, content: userPrompt};

    ai:Prompt systemPrompt = `You are a ${"weather"} assistant.`;
    ai:ChatSystemMessage systemMsg = {role: ai:SYSTEM, content: systemPrompt};

    check store.put(K1, systemMsg);
    check store.put(K1, userMsg);

    check assertSystemMessage(store, K1, systemMsg);
    check assertInteractiveMessages(store, K1, [userMsg]);
    check assertAllMessages(store, K1, [systemMsg, userMsg]);
}

@test:Config {}
function testAssistantMessageWithToolCalls() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    ai:ChatAssistantMessage assistantMsg = {
        role: ai:ASSISTANT,
        content: (),
        toolCalls: [
            {name: "getWeather", arguments: {"city": "Seattle"}, id: "call_1"},
            {name: "getTime", arguments: {"zone": "PST"}, id: "call_2"}
        ]
    };

    check store.put(K1, K1M1);
    check store.put(K1, assistantMsg);
    check assertInteractiveMessages(store, K1, [K1M1, assistantMsg]);
    check assertAllMessages(store, K1, [K1M1, assistantMsg]);
}

@test:Config {}
function testFunctionMessageRoundTrip() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL});
    ai:ChatFunctionMessage funcMsg = {role: "function", name: "getWeather", id: "fn_1"};
    check store.put(K1, funcMsg);
    check assertInteractiveMessages(store, K1, [funcMsg]);
}

// =====================================================================
// Trim / overflow integration tests via `ai:ShortTermMemory`
// =====================================================================

@test:Config {}
function testTrimOverflowWithShortTermMemory() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 4);
    ai:ShortTermMemory memory = check new (store, <ai:TrimOverflowHandlerConfiguration>{trimCount: 2});

    ai:ChatUserMessage m1 = {role: ai:USER, content: "message 1"};
    ai:ChatUserMessage m2 = {role: ai:USER, content: "message 2"};
    ai:ChatUserMessage m3 = {role: ai:USER, content: "message 3"};
    ai:ChatUserMessage m4 = {role: ai:USER, content: "message 4"};
    ai:ChatUserMessage m5 = {role: ai:USER, content: "message 5"};
    ai:ChatUserMessage m6 = {role: ai:USER, content: "message 6"};

    check memory.update(K1, m1);
    check memory.update(K1, m2);
    check memory.update(K1, m3);
    check memory.update(K1, m4);

    // Store holds [m1, m2, m3, m4] - exactly at capacity.
    ai:ChatMessage[] afterFour = check memory.get(K1);
    test:assertEquals(afterFour.length(), 4);

    // Overflow: the two oldest messages are trimmed before m5 is stored.
    check memory.update(K1, m5);
    ai:ChatMessage[] afterFive = check memory.get(K1);
    test:assertEquals(afterFive.length(), 3);
    assertChatMessageEquals(afterFive[0], m3);
    assertChatMessageEquals(afterFive[2], m5);

    // No overflow here - back to capacity.
    check memory.update(K1, m6);
    ai:ChatMessage[] afterSix = check memory.get(K1);
    test:assertEquals(afterSix.length(), 4);
    assertChatMessageEquals(afterSix[0], m3);
    assertChatMessageEquals(afterSix[3], m6);
}

@test:Config {}
function testTrimOverflowPreservesSystemMessage() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 3);
    ai:ShortTermMemory memory = check new (store, <ai:TrimOverflowHandlerConfiguration>{trimCount: 1});

    check memory.update(K1, K1SM1);
    check memory.update(K1, K1M1);
    check memory.update(K1, k1m2);
    check memory.update(K1, K1M3);
    // Overflow trims one interactive message; the system message must survive.
    check memory.update(K1, K1M4);

    ai:ChatMessage[] messages = check memory.get(K1);
    ai:ChatMessage first = messages[0];
    test:assertTrue(first is ai:ChatSystemMessage, "System message must be retained after trimming");
    test:assertEquals(messages.length(), 4);
}

@test:Config {}
function testShortTermMemoryIntegrationWithSystemMessage() returns error? {
    ShortTermMemoryStore store = check new ({url: IN_MEMORY_URL}, 10);
    ai:ShortTermMemory memory = check new (store);

    check memory.update(K1, K1SM1);
    check memory.update(K1, K1M1);
    check memory.update(K1, k1m2);

    ai:ChatMessage[] messages = check memory.get(K1);
    test:assertEquals(messages.length(), 3);
    assertChatMessageEquals(messages[0], K1SM1);
    assertChatMessageEquals(messages[1], K1M1);
    assertChatMessageEquals(messages[2], k1m2);

    check memory.delete(K1);
    ai:ChatMessage[] afterDelete = check memory.get(K1);
    test:assertEquals(afterDelete.length(), 0);
}
