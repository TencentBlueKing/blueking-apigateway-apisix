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

log_level('debug');
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
            local plugin = require("apisix.plugins.bk-legacy-invalid-params")
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
                            "bk-legacy-invalid-params": {
                            },
                            "mocking": {
                                "content_type": "text/plain",
                                "response_status": 200,
                                "response_example": "args:$args\n"
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1982": 1
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
--- response_body
passed
=== TEST 3: call no args
--- request
GET /hello
--- response_body
args:

=== TEST 4: call with normal args
--- request
GET /hello?a=1&b=2
--- response_body
args:a=1&b=2

=== TEST 5: call with `;`
--- request
GET /hello?a=1;b=2
--- response_body
args:a=1&b=2

=== TEST 6: call with `&amp;`
--- request
GET /hello?a=1&amp;b=2
--- response_body
args:a=1&amp&b=2

=== TEST 7: call with `&amp;amp;`
--- request
GET /hello?a=1&amp;amp;b=2
--- response_body
args:a=1&amp&amp&b=2


