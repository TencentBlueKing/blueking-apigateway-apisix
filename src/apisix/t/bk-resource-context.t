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
no_shuffle();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: sanity
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-resource-context")
            local ok, err = plugin.check_schema({
                bk_resource_id = 1,
                bk_resource_name = "resource",
                bk_resource_auth = {
                    verified_app_required = true,
                    verified_user_required = true,
                    resource_perm_required = false,
                    skip_user_verification = true
                }
            })
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 2: add route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "plugins": {
                            "bk-resource-context": {
                                "bk_resource_id": 1,
                                "bk_resource_name": "resource",
                                "bk_resource_auth": {
                                    "verified_app_required": true,
                                    "verified_user_required": true,
                                    "resource_perm_required": false,
                                    "skip_user_verification": true
                                }
                            },
                            "serverless-post-function": {
                                "phase": "rewrite",
                                "functions" : ["return function(conf, ctx) ngx.say(string.format(\"bk_resource_id: %d, bk_resource_name: %s, bk_resource_auth: %s\", ctx.var.bk_resource_id, ctx.var.bk_resource_name, require(\"toolkit.json\").encode(ctx.var.bk_resource_auth))); ngx.exit(200); end"]
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
            -- code is 201, body is passed
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: check ctx var
--- request
GET /hello HTTP/1.1
--- response_body
bk_resource_id: 1, bk_resource_name: resource, bk_resource_auth: {"resource_perm_required":false,"skip_user_verification":true,"verified_app_required":true,"verified_user_required":true}
