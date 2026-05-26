
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
BEGIN {
    if ($ENV{TEST_NGINX_CHECK_LEAK}) {
        $SkipReason = "unavailable for the hup tests";

    } else {
        $ENV{TEST_NGINX_USE_HUP} = 1;
        undef $ENV{TEST_NGINX_USE_STAP};
    }
}

use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_shuffle();
no_root_location();
run_tests;

__DATA__

=== TEST 1: sanity
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-tenant-validate-exempt")
            local ok, err = plugin.check_schema({})
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done

=== TEST 2: set bk_skip_tenant_validate in ctx
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-tenant-validate-exempt")
            local ctx = {
                var = {},
            }
            plugin.rewrite({}, ctx)
            if ctx.var.bk_skip_tenant_validate then
                ngx.say("skip_tenant_validate: true")
            else
                ngx.say("skip_tenant_validate: false")
            end
        }
    }
--- request
GET /t
--- response_body
skip_tenant_validate: true

=== TEST 3: add route with both exempt and validate plugins
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-tenant-validate-exempt": {},
                        "bk-tenant-validate": {
                            "tenant_mode": "single",
                            "tenant_id": "tenant_a"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/hello"
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

=== TEST 4: request should pass tenant validate when exempt is present
Cross-tenant header would normally be rejected, but exempt skips the validate check.
--- request
GET /hello HTTP/1.1
--- more_headers
X-Bk-Tenant-Id: different_tenant
--- response_status: 200
