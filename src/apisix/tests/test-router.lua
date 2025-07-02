--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2017 THL A29 Limited, a Tencent company. All rights reserved.
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

local base_router = require("apisix.http.route")
local ngx_re = require("ngx.re")

describe(
    "radixtree router",
    function()
        local new_router = function(uri, with_parameter)
            local cached_routes = {}
            local uri_router =
                base_router.create_radixtree_uri_router(
                {
                    {
                        value = {uri = uri}
                    }
                },
                cached_routes,
                with_parameter
            )

            return uri_router, cached_routes
        end

        local match_uri = function(router, uri)
            local ctx = {
                var = {
                    request_method = "GET",
                    host = "www.example.com",
                    remote_addr = "127.0.0.1",
                    uri = uri
                }
            }

            local result = base_router.match_uri(router,  ctx)
            return result
        end

        context(
            "ends with parameter",
            function ()
                it(
                    "ends with parameter",
                    function()
                        local router = new_router("/api/v1/users/:id/", true)

                        -- FIXME: failed here, the 3.2.1 is_ture
                        assert.is_true(match_uri(router, "/api/v1/users/1"))
                        assert.is_nil(match_uri(router, "/api/v1/users/1/"))
                    end
                )

                it(
                    "ends with parameter",
                    function()
                        local router = new_router("/api/v1/users/:id/?", true)

                        assert.is_true(match_uri(router, "/api/v1/users/1"))
                        assert.is_true(match_uri(router, "/api/v1/users/1/"))

                        assert.is_nil(match_uri(router, "/api/v1/users/1/?"))
                        assert.is_nil(match_uri(router, "/api/v1/users"))
                        assert.is_nil(match_uri(router, "/api/v1/users/"))
                    end
                )
            end
        )

        it(
            "no parameter",
            function()
                local router = new_router("/api/v1/users/id/", true)

                assert.is_nil(match_uri(router, "/api/v1/users/id"))
                assert.is_true(match_uri(router, "/api/v1/users/id/"))
            end
        )

        it(
            "no parameter and no slash",
            function()
                local router = new_router("/api/v1/users/id", true)

                assert.is_true(match_uri(router, "/api/v1/users/id"))
                assert.is_nil(match_uri(router, "/api/v1/users/id/"))
            end
        )

        it(
            "ending parameter",
            function()
                local router = new_router("/api/v1/users/*extras", true)

                assert.is_nil(match_uri(router, "/api/v1/users"))
                assert.is_true(match_uri(router, "/api/v1/users/"))
                assert.is_true(match_uri(router, "/api/v1/users/id"))
                assert.is_true(match_uri(router, "/api/v1/users/id/"))
            end
        )
    end
)

describe(
    "ngx_re split abnormal feature",
    function ()
        it(
            "no ending slash",
            function ()
                local str = "/path/to/a"
                local splited = ngx_re.split(str, "/")
                assert.is_equal(4, #splited)
                assert.is_equal("", splited[1])
                assert.is_equal("to", splited[3])
                assert.is_equal("a", splited[4])
            end
        )

        it(
            "ending slash",
            function ()
                local str = "/path/to/a/"
                local splited = ngx_re.split(str, "/")
                assert.is_equal(4, #splited)
                assert.is_equal("", splited[1])
                assert.is_equal("to", splited[3])
                assert.is_equal("a", splited[4])
            end
        )
    end
)
