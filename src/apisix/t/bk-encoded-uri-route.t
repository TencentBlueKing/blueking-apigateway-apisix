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
no_shuffle();
no_root_location();

run_tests;

__DATA__

=== TEST 1: match a decoded Chinese parameter against an encoded route
--- config
    location /t {
        content_by_lua_block {
            local route = require("apisix.http.route")
            local route_conf = {
                value = {
                    id = "1",
                    uri = "/resource/%E4%B8%AD%E6%96%87/:id",
                },
            }
            local uri_routes = {}
            local uri_router = route.create_radixtree_uri_router(
                {route_conf}, uri_routes, true)
            local api_ctx = {
                var = {
                    uri = "/resource/中文/123",
                    request_method = "GET",
                    host = "localhost",
                    remote_addr = "127.0.0.1",
                },
            }

            local ok = route.match_uri(uri_router, api_ctx)
            ngx.say(ok)
        }
    }
--- request
GET /t
--- response_body
true
