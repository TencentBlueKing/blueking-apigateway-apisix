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

log_level('debug');
worker_connections(1024);
repeat_each(1);
no_long_string();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__
=== TEST 1: sanity
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-request-id")
            local ok, err = plugin.check_schema({})
            if not ok then
                ngx.say(err)
            end
            ngx.say("done")
        }
    }
--- response_body
done
=== TEST 2: add plugin
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                        "plugins": {
                            "bk-request-id": {
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1982": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/opentracing"
                }]]
                )
            if code >= 300 then
                ngx.status = code
            end
            -- code is 201, body is passed
            ngx.say(body)
        }
    }
--- response_body
passed
=== TEST 3: check for request id in response header (default header name)
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            local uri = "http://127.0.0.1:" .. ngx.var.server_port .. "/opentracing"
            local res, err = httpc:request_uri(uri,
                {
                    method = "GET",
                    headers = {
                        ["Content-Type"] = "application/json",
                    }
                })
            if res.headers["X-Bkapi-Request-Id"] then
                ngx.say("request header present")
            else
                ngx.say("failed")
            end
        }
    }
--- response_body
request header present
=== TEST 4: check the length of request id is 36
--- request
GET /opentracing
--- response_headers_like
X-Bkapi-Request-Id: [a-zA-Z0-9-]{36}

=== TEST 5: error log request ID matches X-Bkapi-Request-ID
--- config
    location /t {
        set $apisix_request_id $request_id;
        lua_error_log_request_id $apisix_request_id;
        rewrite_by_lua_block {
            local core = require("apisix.core")
            local plugin = require("apisix.plugins.bk-request-id")
            local ctx = {}
            core.ctx.set_vars_meta(ctx)
            ngx.ctx.api_ctx = ctx
            plugin.rewrite({}, ctx)
        }
        content_by_lua_block {
            local ctx = ngx.ctx.api_ctx
            assert(ngx.var.apisix_request_id == ctx.var.bk_request_id)
            ngx.log(ngx.WARN, "bk-request-id log correlation: ", ctx.var.bk_request_id)
            ngx.say("matched")
        }
        header_filter_by_lua_block {
            local plugin = require("apisix.plugins.bk-request-id")
            local ctx = ngx.ctx.api_ctx
            plugin.header_filter({}, ctx)
            assert(ngx.header["X-Bkapi-Request-ID"] == ngx.var.apisix_request_id)
        }
    }
--- more_headers
X-Request-ID: client-request-id
--- response_body
matched
--- response_headers_like
X-Bkapi-Request-Id: [0-9a-f-]{36}
--- response_headers
X-Request-Id: client-request-id
--- error_log eval
qr/bk-request-id log correlation: ([0-9a-f-]{36}).*request_id: "\1"$/
--- no_error_log
[error]
