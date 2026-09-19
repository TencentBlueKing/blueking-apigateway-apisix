#
# TencentBlueKing is pleased to support the open source community by making
# 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
# Copyright (C) Tencent. All rights reserved.
# Licensed under the MIT License (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
# http://opensource.org/licenses/MIT
#
# Unless required by applicable law or agreed to in writing, software distributed under
# the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
# either express or implied. See the License for the specific language governing permissions and
# limitations under the License.
#
# We undertake not to change the open source license (MIT license) applicable
# to the current version of the project delivered to anyone in the future.
#

use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;
    $block->set_value("request", "GET /t");
    $block->set_value("http_config", "lua_shared_dict prometheus_patch_test 4m;");
});

run_tests;

__DATA__

=== TEST 1: expired re-add does not scan the historical index in another instance
--- config
    location /t {
        content_by_lua_block {
            local KeyIndex = require("prometheus_keys")
            local dict = ngx.shared.prometheus_patch_test
            -- Independent local indexes model workers sharing one real dictionary.
            local writer = KeyIndex.new(dict, "test_")
            local reader = KeyIndex.new(dict, "test_")
            assert(not writer:add("expiring", "evicted", 60))
            for i = 1, 1000 do
                assert(not writer:add("history_" .. i, "evicted"))
            end
            reader:sync()

            local scanned = 0
            reader.sync_range = function(self, first, last)
                scanned = scanned + last - first + 1
                return KeyIndex.sync_range(self, first, last)
            end
            local old_slot = writer.index.expiring
            assert(dict:expire(writer.key_prefix .. old_slot, 0.001))
            ngx.sleep(0.02)
            assert(not writer:add("expiring", "evicted", 60))
            assert(writer.index.expiring ~= old_slot, "expired metric must move to a new slot")
            assert(not reader:add("history_1000", "evicted"))
            ngx.say("incremental=", scanned >= 1 and scanned <= 4)
            ngx.say("keys=", #reader:list())

            -- Explicit deletion must still invalidate the other local index.
            assert(not writer:remove("expiring", "evicted"))
            ngx.say("after_delete=", #reader:list())
            assert(not writer:add("expiring", "evicted", 60))
            ngx.say("after_recreate=", #reader:list())
        }
    }
--- response_body
incremental=true
keys=1001
after_delete=1000
after_recreate=1001
--- no_error_log
[error]


=== TEST 2: periodic cleanup of an old slot preserves the re-added metric
--- config
    location /t {
        content_by_lua_block {
            local KeyIndex = require("prometheus_keys")
            local dict = ngx.shared.prometheus_patch_test
            local writer = KeyIndex.new(dict, "test2_")
            local reader = KeyIndex.new(dict, "test2_")
            assert(not writer:add("expiring", "evicted", 60))
            assert(not writer:add("permanent", "evicted"))
            reader:sync()

            for _ = 1, 3 do
                assert(dict:expire(writer.key_prefix .. writer.index.expiring, 0.001))
                ngx.sleep(0.02)
                assert(not writer:add("expiring", "evicted", 60))
                reader:sync()
                reader:remove_expired_keys()
                local keys = reader:list()
                table.sort(keys)
                ngx.say(table.concat(keys, ","))
            end
        }
    }
--- response_body
expiring,permanent
expiring,permanent
expiring,permanent
--- no_error_log
[error]


=== TEST 3: syncing an obsolete slot does not clear the current slot mapping
--- config
    location /t {
        content_by_lua_block {
            local KeyIndex = require("prometheus_keys")
            local dict = ngx.shared.prometheus_patch_test
            local writer = KeyIndex.new(dict, "test3_")
            local reader = KeyIndex.new(dict, "test3_")
            assert(not writer:add("expiring", "evicted", 60))
            local old = writer.index.expiring
            assert(not writer:add("permanent", "evicted"))
            reader:sync()
            assert(dict:expire(writer.key_prefix .. old, 0.001))
            ngx.sleep(0.02)
            assert(not writer:add("expiring", "evicted", 60))
            reader:sync()
            local current = reader.index.expiring

            -- A range cleanup must only clear mappings owned by that range.
            reader:sync_range(old, old)
            ngx.say("mapping_preserved=", reader.index.expiring == current)
            ngx.say("current_slot_live=", dict:get(reader.key_prefix .. current) == "expiring")
        }
    }
--- response_body
mapping_preserved=true
current_slot_live=true
--- no_error_log
[error]


=== TEST 4: counters and histograms remain unique after expiry, re-add and cleanup
--- extra_init_worker_by_lua
    local Prometheus = require("prometheus")
    package.loaded.prometheus_patch_instances = {
        writer = Prometheus.init("prometheus_patch_test"),
        reader = Prometheus.init("prometheus_patch_test"),
    }
--- config
    location /t {
        content_by_lua_block {
            local instances = package.loaded.prometheus_patch_instances
            local writer, reader = instances.writer, instances.reader
            local counter = writer:counter("requests_total", "Requests", {"route"}, 60)
            local histogram = writer:histogram("latency", "Latency", {"route"}, {1, 2}, 60)
            local function record()
                counter:inc(1, {"test"})
                histogram:observe(0.5, {"test"})
                writer._counter:sync()
            end
            record()
            reader:metric_data()

            for _ = 1, 3 do
                for key, slot in pairs(writer.key_index.index) do
                    if key:find('route="test"', 1, true) then
                        assert(writer.dict:expire(writer.key_index.key_prefix .. slot, 0.001))
                        assert(writer.dict:expire(key, 0.001))
                    end
                end
                ngx.sleep(0.02)
                record()
                reader.key_index:sync()
                reader.key_index:remove_expired_keys()
                local data = table.concat(reader:metric_data())
                local samples, seen = 0, {}
                for line in data:gmatch("[^\n]+") do
                    if line:sub(1, 1) ~= "#" and line:find('route="test"', 1, true) then
                        local name = line:match("^(.*) [^ ]+$")
                        assert(not seen[name], "duplicate sample: " .. name)
                        seen[name] = true
                        samples = samples + 1
                    end
                end
                ngx.say("samples=", samples)
                ngx.say("counter=", data:find('requests_total{route="test"} 1\n', 1, true) ~= nil)
                ngx.say("histogram=", data:find('latency_count{route="test"} 1\n', 1, true) ~= nil)
            end
        }
    }
--- response_body
samples=6
counter=true
histogram=true
samples=6
counter=true
histogram=true
samples=6
counter=true
histogram=true
--- no_error_log
[error]


=== TEST 5: a recreated key counter must not hide a replacement below the last seen slot
--- config
    location /t {
        content_by_lua_block {
            local KeyIndex = require("prometheus_keys")
            local dict = ngx.shared.prometheus_patch_test
            for extra = 0, 2 do
                local prefix = "reset_" .. extra .. "_"
                local writer = KeyIndex.new(dict, prefix)
                local reader = KeyIndex.new(dict, prefix)
                assert(not writer:add("old", "evicted", 60))
                assert(not writer:add("expiring", "evicted", 60))
                writer:sync()
                reader:sync()
                assert(dict:expire(writer.key_prefix .. writer.index.old, 0.001))
                assert(dict:expire(writer.key_prefix .. writer.index.expiring, 0.001))
                ngx.sleep(0.02)
                -- Model counter eviction, then let it recover below, equal to,
                -- or above the reader's previous watermark before it syncs.
                dict:delete(writer.key_count)
                assert(not writer:add("expiring", "evicted", 60))
                for i = 1, extra do
                    assert(not writer:add("new_" .. i, "evicted"))
                end
                reader:sync()
                reader:remove_expired_keys()
                local keys = reader:list()
                table.sort(keys)
                ngx.say("keys=", table.concat(keys, ","))
                ngx.say("current_slot=", reader.index.expiring == writer.index.expiring)
            end
        }
    }
--- response_body
keys=expiring
current_slot=true
keys=expiring,new_1
current_slot=true
keys=expiring,new_1,new_2
current_slot=true
--- no_error_log
[error]


=== TEST 6: a slot lost between get and ttl is reclaimed without a full sync
--- config
    location /t {
        content_by_lua_block {
            local KeyIndex = require("prometheus_keys")
            local dict = ngx.shared.prometheus_patch_test
            local writer = KeyIndex.new(dict, "ttl_race_")
            assert(not writer:add("expiring", "evicted", 60))
            assert(not writer:add("anchor", "evicted"))
            local old_slot = writer.index.expiring
            local shared_key = writer.key_prefix .. old_slot
            local reader_dict = setmetatable({}, {
                __index = function(_, method)
                    return function(_, ...)
                        return dict[method](dict, ...)
                    end
                end
            })
            reader_dict.get = function(_, key)
                local value, err = dict:get(key)
                if key == shared_key and value then
                    -- Model another worker removing the real slot after get
                    -- succeeds but before sync_range queries its TTL.
                    dict:delete(key)
                end
                return value, err
            end
            local reader = KeyIndex.new(reader_dict, "ttl_race_")
            reader:sync()
            ngx.say("tracked=", reader.expire_keys[old_slot] == true)

            local scanned = 0
            reader.sync_range = function(self, first, last)
                scanned = scanned + last - first + 1
                return KeyIndex.sync_range(self, first, last)
            end
            assert(not writer:add("expiring", "evicted", 60))
            reader:sync()
            local current = reader.index.expiring
            assert(current ~= old_slot)
            reader:remove_expired_keys()
            ngx.say("old_slot_removed=", reader.keys[old_slot] == nil
                    and reader.expire_keys[old_slot] == nil)
            ngx.say("mapping_preserved=", reader.index.expiring == current
                    and dict:get(reader.key_prefix .. current) == "expiring")
            ngx.say("keys=", #reader:list())
            ngx.say("incremental=", scanned >= 1 and scanned <= 4)
            ngx.say("broadcasts=", dict:get(reader.delete_count) or 0)
        }
    }
--- response_body
tracked=true
old_slot_removed=true
mapping_preserved=true
keys=2
incremental=true
broadcasts=0
--- no_error_log
[error]


=== TEST 7: a TTL query error defers cleanup until the slot is confirmed missing
--- config
    location /t {
        content_by_lua_block {
            local KeyIndex = require("prometheus_keys")
            local dict = ngx.shared.prometheus_patch_test
            local writer = KeyIndex.new(dict, "ttl_error_")
            assert(not writer:add("expiring", "evicted", 60))
            assert(not writer:add("permanent", "evicted"))
            local slot = writer.index.expiring
            local shared_key = writer.key_prefix .. slot
            local fail_ttl = true
            local reader_dict = setmetatable({}, {
                __index = function(_, method)
                    return function(_, ...)
                        return dict[method](dict, ...)
                    end
                end
            })
            reader_dict.ttl = function(_, key)
                if fail_ttl and key == shared_key then
                    return nil, "injected TTL query error"
                end
                return dict:ttl(key)
            end
            local reader = KeyIndex.new(reader_dict, "ttl_error_")
            reader:sync()
            ngx.say("tracked=", reader.expire_keys[slot] == true)
            ngx.say("permanent_untracked=",
                    reader.expire_keys[reader.index.permanent] == nil)
            reader:remove_expired_keys()
            ngx.say("kept_on_error=", reader.keys[slot] == "expiring"
                    and reader.index.expiring == slot)
            fail_ttl = false
            reader:remove_expired_keys()
            ngx.say("kept_while_live=", reader.keys[slot] == "expiring")
            dict:delete(shared_key)
            reader:remove_expired_keys()
            ngx.say("removed_when_missing=", reader.keys[slot] == nil
                    and reader.index.expiring == nil and reader.expire_keys[slot] == nil)
            ngx.say("keys=", #reader:list())
            ngx.say("broadcasts=", dict:get(reader.delete_count) or 0)
        }
    }
--- response_body
tracked=true
permanent_untracked=true
kept_on_error=true
kept_while_live=true
removed_when_missing=true
keys=1
broadcasts=0
--- no_error_log
[error]
