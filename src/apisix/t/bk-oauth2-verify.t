#
# TencentBlueKing is pleased to support the open source community by making
# 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
# Copyright (C) 2025 Tencent. All rights reserved.
# Licensed under the MIT License (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
#     http://opensource.org/licenses/MIT
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
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: sanity - check_schema
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-verify")
            local ok, err = plugin.check_schema({})
            if not ok then
                ngx.say(err)
                return
            end

            ngx.say("done")
        }
    }
--- response_body
done

=== TEST 2: should skip when is_bk_oauth2 is not set
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-verify")
            local ctx = {
                var = {}
            }

            local result = plugin.rewrite({}, ctx)
            if result == nil then
                ngx.say("skipped")
            else
                ngx.say("processed")
            end
        }
    }
--- response_body
skipped

=== TEST 3: should skip when is_bk_oauth2 is false
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-verify")
            local ctx = {
                var = {
                    is_bk_oauth2 = false
                }
            }

            local result = plugin.rewrite({}, ctx)
            if result == nil then
                ngx.say("skipped")
            else
                ngx.say("processed")
            end
        }
    }
--- response_body
skipped

=== TEST 4: should set all expected ctx.var after successful verification
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-verify")
            local core = require("apisix.core")
            
            -- Mock core.request.header to return Authorization header
            local original_header = core.request.header
            core.request.header = function(ctx, name)
                if name == "Authorization" then
                    return "Bearer valid-token"
                end
                return nil
            end

            -- Mock the cache to return a valid result
            local oauth2_cache = require("apisix.plugins.bk-cache.oauth2-access-token")
            local original_get = oauth2_cache.get_oauth2_access_token
            oauth2_cache.get_oauth2_access_token = function(token)
                return {
                    active = true,
                    exp = 4102444800,
                    bk_app_code = "test-app",
                    bk_username = "test-user",
                    audience = {"gateway:demo/api:test", "mcp_server:my-server"}
                }, nil
            end

            local ctx = {
                var = {
                    is_bk_oauth2 = true
                }
            }

            local result = plugin.rewrite({}, ctx)
            
            -- Restore original functions
            core.request.header = original_header
            oauth2_cache.get_oauth2_access_token = original_get

            -- Check all expected ctx.var are set
            local errors = {}

            if not ctx.var.bk_app then
                table.insert(errors, "bk_app is nil")
            elseif ctx.var.bk_app.app_code ~= "test-app" then
                table.insert(errors, "bk_app.app_code mismatch")
            end

            if not ctx.var.bk_user then
                table.insert(errors, "bk_user is nil")
            elseif ctx.var.bk_user.username ~= "test-user" then
                table.insert(errors, "bk_user.username mismatch")
            end

            if ctx.var.bk_app_code ~= "test-app" then
                table.insert(errors, "bk_app_code mismatch")
            end

            if ctx.var.bk_username ~= "test-user" then
                table.insert(errors, "bk_username mismatch")
            end

            if not ctx.var.audience or #ctx.var.audience ~= 2 then
                table.insert(errors, "audience mismatch")
            end

            if ctx.var.auth_params_location ~= "header" then
                table.insert(errors, "auth_params_location mismatch")
            end

            if result ~= nil then
                table.insert(errors, "result should be nil but got: " .. tostring(result))
            end

            if #errors > 0 then
                ngx.say("FAILED: " .. table.concat(errors, "; "))
            else
                ngx.say("pass")
            end
        }
    }
--- response_body
pass

=== TEST 5: should set bk_app with verified=true
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-verify")
            local core = require("apisix.core")
            
            local original_header = core.request.header
            core.request.header = function(ctx, name)
                if name == "Authorization" then return "Bearer token" end
                return nil
            end
            
            local oauth2_cache = require("apisix.plugins.bk-cache.oauth2-access-token")
            local original_get = oauth2_cache.get_oauth2_access_token
            oauth2_cache.get_oauth2_access_token = function(token)
                return { active = true, exp = 4102444800, bk_app_code = "my-app", bk_username = "my-user",
                         audience = {} }, nil
            end

            local ctx = { var = { is_bk_oauth2 = true } }

            plugin.rewrite({}, ctx)
            core.request.header = original_header
            oauth2_cache.get_oauth2_access_token = original_get

            if ctx.var.bk_app and ctx.var.bk_app.verified == true then
                ngx.say("pass")
            else
                ngx.say("fail: verified=" .. tostring(ctx.var.bk_app and ctx.var.bk_app.verified))
            end
        }
    }
--- response_body
pass

=== TEST 6: should set bk_user with correct verified status
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-verify")
            local core = require("apisix.core")
            
            local original_header = core.request.header
            core.request.header = function(ctx, name)
                if name == "Authorization" then return "Bearer token" end
                return nil
            end
            
            local oauth2_cache = require("apisix.plugins.bk-cache.oauth2-access-token")
            local original_get = oauth2_cache.get_oauth2_access_token
            oauth2_cache.get_oauth2_access_token = function(token)
                return { active = true, exp = 4102444800, bk_app_code = "app", bk_username = "valid-user",
                         audience = {} }, nil
            end

            local ctx = { var = { is_bk_oauth2 = true } }

            plugin.rewrite({}, ctx)
            core.request.header = original_header
            oauth2_cache.get_oauth2_access_token = original_get

            if ctx.var.bk_user and ctx.var.bk_user.verified == true and ctx.var.bk_user.username == "valid-user" then
                ngx.say("pass")
            else
                ngx.say("fail")
            end
        }
    }
--- response_body
pass

=== TEST 7: should set bk_user verified=false when username is empty
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-verify")
            local core = require("apisix.core")
            
            local original_header = core.request.header
            core.request.header = function(ctx, name)
                if name == "Authorization" then return "Bearer token" end
                return nil
            end
            
            local oauth2_cache = require("apisix.plugins.bk-cache.oauth2-access-token")
            local original_get = oauth2_cache.get_oauth2_access_token
            oauth2_cache.get_oauth2_access_token = function(token)
                return { active = true, exp = 4102444800, bk_app_code = "app", bk_username = "",
                         audience = {} }, nil
            end

            local ctx = { var = { is_bk_oauth2 = true } }

            plugin.rewrite({}, ctx)
            core.request.header = original_header
            oauth2_cache.get_oauth2_access_token = original_get

            if ctx.var.bk_user and ctx.var.bk_user.verified == false and ctx.var.bk_user.username == "" then
                ngx.say("pass")
            else
                ngx.say("fail: verified=" .. tostring(ctx.var.bk_user and ctx.var.bk_user.verified))
            end
        }
    }
--- response_body
pass

=== TEST 8: should set auth_params_location to header
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-verify")
            local core = require("apisix.core")
            
            local original_header = core.request.header
            core.request.header = function(ctx, name)
                if name == "Authorization" then return "Bearer token" end
                return nil
            end
            
            local oauth2_cache = require("apisix.plugins.bk-cache.oauth2-access-token")
            local original_get = oauth2_cache.get_oauth2_access_token
            oauth2_cache.get_oauth2_access_token = function(token)
                return { active = true, exp = 4102444800, bk_app_code = "app", bk_username = "user",
                         audience = {} }, nil
            end

            local ctx = { var = { is_bk_oauth2 = true } }

            plugin.rewrite({}, ctx)
            core.request.header = original_header
            oauth2_cache.get_oauth2_access_token = original_get

            ngx.say(ctx.var.auth_params_location)
        }
    }
--- response_body
header
