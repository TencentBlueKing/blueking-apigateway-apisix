#
# TencentBlueKing is pleased to support the open source community by making
# 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
# Copyright (C) Tencent. All rights reserved.
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

log_level('warn');
repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();

run_tests;

__DATA__

=== TEST 1: add the fallback route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1', ngx.HTTP_PUT,
                [[{
                    "uri": "/missing/*",
                    "priority": -1,
                    "plugins": {
                        "bk-not-found-handler": {},
                        "bk-error-wrapper": {}
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed


=== TEST 2: expected 404 preserves the BlueKing error without an exit warning
--- request
GET /missing/api
--- error_code: 404
--- response_headers
X-Bkapi-Error-Code: 1640401
--- response_body_like
"code_name":"API_NOT_FOUND"
--- no_error_log
bk-not-found-handler exits with http status code 404
[error]


=== TEST 3: other plugins still warn when returning 404
--- config
    location /t {
        rewrite_by_lua_block {
            local core = require("apisix.core")
            local ctx = {}
            core.ctx.set_vars_meta(ctx)
            ngx.ctx.api_ctx = ctx
            local plugin = {
                name = "test-not-found",
                rewrite = function()
                    return 404, "other plugin response"
                end,
            }
            require("apisix.plugin").run_plugin("rewrite", {plugin, {}}, ctx)
        }
    }
--- request
GET /t
--- error_code: 404
--- response_body: other plugin response
--- error_log
test-not-found exits with http status code 404
--- no_error_log
[error]


=== TEST 4: unexpected server errors in the fallback plugin still warn
--- config
    location /t {
        rewrite_by_lua_block {
            local core = require("apisix.core")
            local ctx = {}
            core.ctx.set_vars_meta(ctx)
            ngx.ctx.api_ctx = ctx
            -- Exercise the runner's error path without altering the loaded plugin.
            local plugin = {
                name = "bk-not-found-handler",
                rewrite = function()
                    return 500, "unexpected server error"
                end,
            }
            require("apisix.plugin").run_plugin("rewrite", {plugin, {}}, ctx)
        }
    }
--- request
GET /t
--- error_code: 500
--- response_body: unexpected server error
--- error_log
bk-not-found-handler exits with http status code 500
--- no_error_log
[error]


=== TEST 5: suppressing the warning preserves the configured error response
--- config
    location /t {
        rewrite_by_lua_block {
            local core = require("apisix.core")
            local ctx = {}
            core.ctx.set_vars_meta(ctx)
            ngx.ctx.api_ctx = ctx
            local plugin = require("apisix.plugins.bk-not-found-handler")
            local conf = {
                _meta = {
                    error_response = "custom not found response",
                },
            }
            require("apisix.plugin").run_plugin("rewrite", {plugin, conf}, ctx)
        }
    }
--- request
GET /t
--- error_code: 404
--- response_body: custom not found response
--- no_error_log
bk-not-found-handler exits with http status code 404
[error]
