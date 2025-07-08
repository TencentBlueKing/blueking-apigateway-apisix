--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2025 Tencent. All rights reserved.
-- Licensed under the MIT License (the "License"); you may not use this file except
-- in compliance with the License. You may obtain a copy of the License at
--
--     http://opensource.org/licenses/MIT
--
-- Unless required by applicable law or agreed to in writing, software distributed under
-- the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
-- either express or implied. See the License for the specific language governing permissions and
-- limitations under the License.
--
-- We undertake not to change the open source license (MIT license) applicable
-- to the current version of the project delivered to anyone in the future.
--

local cache_fallback = require("apisix.plugins.bk-cache-fallback.init")
local ngx_shared = ngx.shared
local ngx_sleep = ngx.sleep

describe(
    "bk-cache-fallback", function()

        local conf
        local plugin_name

        before_each(
            function()
                conf = {
                    lrucache_max_items = 1024,
                    lrucache_ttl = 60,
                    lrucache_short_ttl = 10,
                    fallback_cache_ttl = 60 * 60,
                }
                plugin_name = "bk-cache-fallback"
            end
        )

        describe(
            "new", function()

                it(
                    "default value", function()
                        local plugin = cache_fallback.new({}, plugin_name)

                        assert.equal(plugin._GLOBAL_LRUCACHE_MAX_ITEMS, plugin.lrucache_max_items)
                        assert.equal(plugin._GLOBAL_LRUCACHE_TTL, plugin.lrucache_ttl)
                        assert.equal(plugin._GLOBAL_LRUCACHE_SHORT_TTL, plugin.lrucache_short_ttl)
                        assert.equal(plugin._GLOBAL_FALLBACK_CACHE_TTL, plugin.fallback_cache_ttl)

                        assert.equal(plugin.plugin_name, plugin.plugin_name)
                        assert.equal(plugin.plugin_name_with_colon, plugin.plugin_name .. ":")
                        assert.equal(plugin.plugin_shared_dict_name, "plugin-" .. plugin.plugin_name)
                        assert.equal(plugin.key_prefix, plugin.plugin_name .. ":")
                    end
                )

                it(
                    "specific value", function()
                        local plugin = cache_fallback.new(
                            {
                                lrucache_max_items = 1,
                                lrucache_ttl = 2,
                                lrucache_short_ttl = 3,
                                fallback_cache_ttl = 4,
                            }, plugin_name
                        )

                        assert.equal(1, plugin.lrucache_max_items)
                        assert.equal(2, plugin.lrucache_ttl)
                        assert.equal(3, plugin.lrucache_short_ttl)
                        assert.equal(4, plugin.fallback_cache_ttl)

                        assert.equal(plugin.plugin_name, plugin.plugin_name)
                        assert.equal(plugin.plugin_name_with_colon, plugin.plugin_name .. ":")
                        assert.equal(plugin.plugin_shared_dict_name, "plugin-" .. plugin.plugin_name)
                        assert.equal(plugin.key_prefix, plugin.plugin_name .. ":")
                    end
                )
            end
        )

        describe(
            "get_with_fallback", function()
                local key
                local f

                before_each(function ()
                    key = "foo"

                    f = {
                        create_obj_func_ok = function() end,
                        create_obj_func_fail = function() end,
                    }


                    stub(f, "create_obj_func_ok", function ()
                        return {
                            ["hello"] = "world",
                        }, nil
                    end)
                    stub(f, "create_obj_func_fail", function ()
                        return nil, "error"
                    end)

                end)

                after_each(function ()
                    f.create_obj_func_ok:revert()
                    f.create_obj_func_fail:revert()
                end)

                -- NOTE: the lrucache and shared_dict with the same plugin_name will make the unittest failed
                --       we should separate them

                it("ok", function ()
                    local ctx = {
                        conf_id = 123,
                        conf_type = "hello",
                    }
                    local cache = cache_fallback.new(conf, "bk-cache-fallback-ok")
                    local cache_key = cache.key_prefix .. key
                    local shared_data_dict = ngx_shared[cache.plugin_shared_dict_name]
                    assert.is_not_nil(shared_data_dict)

                    -- 1. get first time
                    local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_ok)
                    assert.is_not_nil(obj)
                    assert.is_nil(err)
                    assert.equal("world", obj["hello"])

                    assert.stub(f.create_obj_func_ok).was_called(1)

                    -- got data in shared_dict
                    local sd = shared_data_dict:get(cache_key)
                    assert.is_not_nil(sd)
                    assert.equal('{"hello":"world"}', sd)

                    -- 2. get the second time
                    local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_ok)
                    assert.is_not_nil(obj)
                    assert.is_nil(err)
                    assert.equal("world", obj["hello"])

                    -- NOTE: the create_obj_func_ok should be called only once
                    assert.stub(f.create_obj_func_ok).was_called(1)

                    -- got data in shared_dict
                    local sd = shared_data_dict:get(cache_key)
                    assert.is_not_nil(sd)
                    assert.equal('{"hello":"world"}', sd)

                    -- 3. get the third time
                    local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_ok)
                    assert.is_not_nil(obj)
                    assert.is_nil(err)
                    assert.equal("world", obj["hello"])

                    -- NOTE: the create_obj_func_ok should be called only once
                    assert.stub(f.create_obj_func_ok).was_called(1)

                    -- got data in shared_dict
                    local sd = shared_data_dict:get(cache_key)
                    assert.is_not_nil(sd)
                    assert.equal('{"hello":"world"}', sd)
                end)

                it("fail", function ()
                    local ctx = {
                        conf_id = 456,
                        conf_type = "world",
                    }
                    conf = {
                        lrucache_max_items = 1024,
                        lrucache_ttl = 1,
                        lrucache_short_ttl = 1,
                        fallback_cache_ttl = 60 * 60,
                    }

                    local cache = cache_fallback.new(conf, "bk-cache-fallback-fail")
                    local cache_key = cache.key_prefix .. key

                    local shared_data_dict = ngx_shared[cache.plugin_shared_dict_name]
                    assert.is_not_nil(shared_data_dict)

                    -- 1. get first time
                    local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_fail)
                    assert.is_nil(obj)
                    assert.is_not_nil(err)
                    assert.equal("bk-cache-fallback-fail:create_obj_funcs failed and got no data in the shared_dict for fallback", err)

                    assert.stub(f.create_obj_func_fail).was_called(1)

                    -- got data in shared_dict
                    local sd = shared_data_dict:get(cache_key)
                    assert.is_nil(sd)

                    -- 2. get the second time
                    local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_fail)
                    assert.is_nil(obj)
                    assert.is_not_nil(err)
                    assert.equal("bk-cache-fallback-fail:create_obj_funcs failed and got no data in the shared_dict for fallback", err)


                    -- NOTE: the create_obj_func_ok should be called only once
                    assert.stub(f.create_obj_func_fail).was_called(1)

                    -- got data in shared_dict
                    local sd = shared_data_dict:get(cache_key)
                    assert.is_nil(sd)

                    -- 3. get the third time
                    local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_fail)
                    assert.is_nil(obj)
                    assert.is_not_nil(err)
                    assert.equal("bk-cache-fallback-fail:create_obj_funcs failed and got no data in the shared_dict for fallback", err)


                    -- NOTE: the create_obj_func_ok should be called only once
                    assert.stub(f.create_obj_func_fail).was_called(1)

                    -- got data in shared_dict
                    local sd = shared_data_dict:get(cache_key)
                    assert.is_nil(sd)

                    -- 4. sleep for 2 seconds, the lrucache will be expired, get failed too
                    ngx_sleep(2)

                    local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_fail)
                    assert.is_nil(obj)
                    assert.is_not_nil(err)
                    assert.equal("bk-cache-fallback-fail:create_obj_funcs failed and got no data in the shared_dict for fallback", err)


                    -- NOTE: the create_obj_func_ok should be called twice
                    assert.stub(f.create_obj_func_fail).was_called(2)

                    -- got data in shared_dict
                    local sd = shared_data_dict:get(cache_key)
                    assert.is_nil(sd)


                    -- 5. sleep for 2 seconds, the lrucache will be expired, get ok
                    ngx_sleep(2)

                    local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_ok)
                    assert.is_not_nil(obj)
                    assert.is_nil(err)
                    assert.equal("world", obj["hello"])

                    assert.stub(f.create_obj_func_ok).was_called(1)

                    -- got data in shared_dict
                    local sd = shared_data_dict:get(cache_key)
                    assert.is_not_nil(sd)
                    assert.equal('{"hello":"world"}', sd)

                end)

                it("success then fail", function ()
                    local ctx = {
                        conf_id = 456,
                        conf_type = "world",
                    }
                    conf = {
                        lrucache_max_items = 1024,
                        lrucache_ttl = 1,
                        lrucache_short_ttl = 1,
                        fallback_cache_ttl = 60 * 60,
                    }

                    local cache = cache_fallback.new(conf, "bk-cache-fallback-ok-fail")
                    local cache_key = cache.key_prefix .. key

                    local shared_data_dict = ngx_shared[cache.plugin_shared_dict_name]
                    assert.is_not_nil(shared_data_dict)

                    -- 1. get first time, ok
                    local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_ok)
                    assert.is_not_nil(obj)
                    assert.is_nil(err)
                    assert.equal("world", obj["hello"])

                    assert.stub(f.create_obj_func_ok).was_called(1)

                    -- got data in shared_dict
                    local sd = shared_data_dict:get(cache_key)
                    assert.is_not_nil(sd)
                    assert.equal('{"hello":"world"}', sd)

                    -- 5. sleep for 2 seconds, the lrucache will be expired, get ok
                    ngx_sleep(2)

                    -- 2. get the second time, fail
                    local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_fail)
                    assert.is_not_nil(obj)
                    assert.is_nil(err)
                    -- type is table
                    assert.equal("table", type(obj))
                    assert.equal("world", obj["hello"])


                    -- called once
                    assert.stub(f.create_obj_func_fail).was_called(1)

                    -- got data in shared_dict
                    local sd = shared_data_dict:get(cache_key)
                    assert.is_not_nil(sd)
                end)

            end
        )

        -- a new case here, to test the lock:lock timeout and other errors
        describe("lock:lock timeout and other errors", function()
            local key
            local f

            before_each(function ()
                key = "foo"

                f = {
                    create_obj_func_ok = function() end,
                    create_obj_func_fail = function() end,
                }

                stub(f, "create_obj_func_ok", function ()
                    return {
                        ["hello"] = "world",
                    }, nil
                end)
                stub(f, "create_obj_func_fail", function ()
                    return nil, "error"
                end)

            end)

            after_each(function ()
                f.create_obj_func_ok:revert()
                f.create_obj_func_fail:revert()
            end)

            it("is not timeout error, should return the error", function ()
                local ctx = {
                    conf_id = 789,
                    conf_type = "test",
                }
                local cache = cache_fallback.new(conf, "bk-cache-fallback-lock-error")
                local cache_key = cache.key_prefix .. key

                local shared_data_dict = ngx_shared[cache.plugin_shared_dict_name]
                assert.is_not_nil(shared_data_dict)

                -- Stub lock:lock to simulate an error (not timeout)
                local lock = require("resty.lock")
                stub(lock, "lock", function(self, key_s)
                    if key_s == cache_key then
                        return nil, "some error"
                    else
                        return 0, nil
                    end
                end)

                local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_fail)
                assert.is_nil(obj)
                assert.is_not_nil(err)
                assert.equal("failed to acquire the bk-cache-fallback lock, key: bk-cache-fallback-lock-error:foo, err: some error", err)

                lock.lock:revert()
            end)

            it("is timeout, no data in shared_dict, return the error", function ()
                local ctx = {
                    conf_id = 789,
                    conf_type = "test",
                }
                local cache = cache_fallback.new(conf, "bk-cache-fallback-lock-timeout")
                local cache_key = cache.key_prefix .. key

                local shared_data_dict = ngx_shared[cache.plugin_shared_dict_name]
                assert.is_not_nil(shared_data_dict)

                -- Stub lock:lock to simulate a timeout
                local lock = require("resty.lock")
                stub(lock, "lock", function(self, key_s)
                    if key_s == cache_key then
                        return nil, "timeout"
                    else
                        return 0, nil
                    end
                end)

                local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_fail)
                assert.is_nil(obj)
                assert.is_not_nil(err)
                assert.equal("failed to acquire the bk-cache-fallback lock, key: bk-cache-fallback-lock-timeout:foo, error: timeout.", err)

                lock.lock:revert()
            end)

            it("is timeout, got the data in shared_dict, return data,nil", function ()
                local ctx = {
                    conf_id = 789,
                    conf_type = "test",
                }
                local cache = cache_fallback.new(conf, "bk-cache-fallback-lock-timeout-data")
                local cache_key = cache.key_prefix .. key

                local shared_data_dict = ngx_shared[cache.plugin_shared_dict_name]
                assert.is_not_nil(shared_data_dict)

                -- set data in shared_dict
                shared_data_dict:set(cache_key, '{"hello":"abc"}', 60 * 60)

                -- Stub lock:lock to simulate a timeout
                local lock = require("resty.lock")
                stub(lock, "lock", function(self, key_s)
                    if key_s == cache_key then
                        return nil, "timeout"
                    else
                        return 0, nil
                    end
                end)

                local obj, err = cache:get_with_fallback(ctx, key, nil, f.create_obj_func_ok)
                assert.is_not_nil(obj)
                assert.is_nil(err)
                assert.equal("abc", obj["hello"])

                lock.lock:revert()
            end)
        end)
    end
)
