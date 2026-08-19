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

=== TEST 1: existing four-argument response filter remains compatible
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugin")
            local fake = {
                name = "test-four-argument-filter",
                lua_body_filter = function(_, _, _, body)
                    return nil, body .. ":legacy"
                end,
            }
            local api_ctx = {plugins = {fake, {}}, var = {}}
            local ok, err = plugin.lua_response_filter(
                api_ctx, {}, "payload", true, false, true)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- response_body: payload:legacy



=== TEST 2: response filter receives EOF marker
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugin")
            local fake = {
                name = "test-eof-filter",
                lua_body_filter = function(_, _, _, body, eof)
                    return nil, body .. ":eof=" .. tostring(eof)
                end,
            }
            local api_ctx = {plugins = {fake, {}}, var = {}}
            local ok, err = plugin.lua_response_filter(
                api_ctx, {}, "payload", true, false, true)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- response_body: payload:eof=true
