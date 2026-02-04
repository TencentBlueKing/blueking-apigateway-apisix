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
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
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
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {}
            }

            local result = plugin.rewrite({}, ctx)
            if result == nil then
                ngx.say("skipped")
            else
                ngx.say("processed: " .. tostring(result))
            end
        }
    }
--- response_body
skipped

=== TEST 3: test validation logic - should skip when is_bk_oauth2 is false
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = false,
                    bk_gateway_name = "demo",
                    bk_resource_name = "test-api",
                    audience = {}
                }
            }

            local result = plugin.rewrite({}, ctx)
            if result == nil then
                ngx.say("skipped")
            else
                ngx.say("processed: " .. tostring(result))
            end
        }
    }
--- response_body
skipped

=== TEST 4: test validation logic - gateway API match
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "demo",
                    bk_resource_name = "test-api",
                    audience = {"gateway:demo/api:test-api"}
                }
            }

            local result = plugin.rewrite({}, ctx)
            if result == nil then
                ngx.say("pass")
            else
                ngx.say("fail")
            end
        }
    }
--- response_body
pass

=== TEST 5: test validation logic - gateway API wildcard match
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "demo",
                    bk_resource_name = "any-api",
                    audience = {"gateway:demo/api:*"}
                }
            }

            local result = plugin.rewrite({}, ctx)
            if result == nil then
                ngx.say("pass")
            else
                ngx.say("fail")
            end
        }
    }
--- response_body
pass

=== TEST 6: test validation logic - MCP server match
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "bk-apigateway",
                    bk_resource_name = "mcp-resource",
                    uri = "/api/v2/mcp-servers/my-server/resources",
                    audience = {"mcp_server:my-server"}
                }
            }

            local result = plugin.rewrite({}, ctx)
            if result == nil then
                ngx.say("pass")
            else
                ngx.say("fail")
            end
        }
    }
--- response_body
pass

=== TEST 7: test validation logic - multiple audiences - one match
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "demo",
                    bk_resource_name = "test-api",
                    audience = {"gateway:other/api:other", "gateway:demo/api:test-api"}
                }
            }

            local result = plugin.rewrite({}, ctx)
            if result == nil then
                ngx.say("pass")
            else
                ngx.say("fail")
            end
        }
    }
--- response_body
pass

=== TEST 8: test priority value
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            if plugin.priority == 17678 then
                ngx.say("pass")
            else
                ngx.say("fail: " .. tostring(plugin.priority))
            end
        }
    }
--- response_body
pass

=== TEST 9: FAIL - empty audience returns 403
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "demo",
                    bk_resource_name = "test-api",
                    audience = {}
                }
            }

            local status = plugin.rewrite({}, ctx)
            -- status will be 403, and ngx.status is also set to 403
            -- we output the status before the response is finalized
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 403

=== TEST 10: FAIL - nil audience returns 403
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "demo",
                    bk_resource_name = "test-api",
                    audience = nil
                }
            }

            local status = plugin.rewrite({}, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 403

=== TEST 11: FAIL - gateway mismatch returns 403
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "my-gateway",
                    bk_resource_name = "test-api",
                    audience = {"gateway:other-gateway/api:test-api"}
                }
            }

            local status = plugin.rewrite({}, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 403

=== TEST 12: FAIL - API mismatch returns 403
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "demo",
                    bk_resource_name = "my-api",
                    audience = {"gateway:demo/api:other-api"}
                }
            }

            local status = plugin.rewrite({}, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 403

=== TEST 13: FAIL - MCP server mismatch returns 403
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "bk-apigateway",
                    bk_resource_name = "mcp-resource",
                    uri = "/api/v2/mcp-servers/server-a/resources",
                    audience = {"mcp_server:server-b"}
                }
            }

            local status = plugin.rewrite({}, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 403

=== TEST 14: FAIL - MCP server audience with wrong gateway returns 403
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "other-gateway",
                    bk_resource_name = "mcp-resource",
                    uri = "/api/v2/mcp-servers/my-server/resources",
                    audience = {"mcp_server:my-server"}
                }
            }

            local status = plugin.rewrite({}, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 403

=== TEST 15: FAIL - no matching audience in list returns 403
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "demo",
                    bk_resource_name = "my-api",
                    audience = {"gateway:other/api:other", "gateway:another/api:another", "mcp_server:some-server"}
                }
            }

            local status = plugin.rewrite({}, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 403

=== TEST 16: FAIL - unknown audience format is ignored and returns 403
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-audience-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = true,
                    bk_gateway_name = "demo",
                    bk_resource_name = "my-api",
                    audience = {"unknown:format", "invalid-audience"}
                }
            }

            local status = plugin.rewrite({}, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 403
