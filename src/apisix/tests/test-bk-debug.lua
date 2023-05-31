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

local core = require("apisix.core")
local plugin = require("apisix.plugins.bk-debug")

describe(
    "bk-debug", function()
        local ctx
        local client_ip
        local request_headers

        before_each(
            function()
                ctx = {
                    var = {
                        bk_request_id = "unique-foo-id",
                        bk_app_code = "fake-app",
                        bk_username = "admin",
                        instance_id = "fake-instance-id",
                    },
                }

                stub(
                    core.request, "get_remote_client_ip", function()
                        return client_ip
                    end
                )
                stub(
                    core.request, "headers", function()
                        return request_headers
                    end
                )
                stub(
                    core.request, "header", function(ctx, header)
                        return request_headers[header]
                    end
                )
            end
        )

        after_each(
            function()
                core.request.get_remote_client_ip:revert()
                core.request.headers:revert()
                core.request.header:revert()
            end
        )

        context(
            "get_debug_info", function()
                it(
                    "ok", function()
                        client_ip = "1.1.1.1"
                        request_headers = {
                            foo = "bar",
                        }

                        local debug_info = plugin._get_debug_info(ctx)
                        assert.is_same(
                            debug_info, {
                                bk_request_id = "unique-foo-id",
                                bk_app_code = "fake-app",
                                bk_username = "admin",
                                instance_id = "fake-instance-id",
                                client_ip = "1.1.1.1",
                                request_headers = {
                                    foo = "bar",
                                },
                            }
                        )
                    end
                )
            end
        )

        context(
            "header_filter", function()
                before_each(
                    function()
                        stub(core.response, "set_header")
                    end
                )

                after_each(
                    function()
                        core.response.set_header:revert()
                    end
                )

                it(
                    "has debug info", function()
                        client_ip = "10.0.0.1"
                        request_headers = {
                            ["X-Bkapi-Debug"] = "true",
                            foo = "bar",
                        }
                        plugin.header_filter({}, ctx)

                        assert.stub(core.response.set_header).was_called_with(
                            "X-Bkapi-Debug-Info", core.json.encode(
                                {
                                    bk_request_id = "unique-foo-id",
                                    bk_app_code = "fake-app",
                                    bk_username = "admin",
                                    instance_id = "fake-instance-id",
                                    client_ip = "10.0.0.1",
                                    request_headers = {
                                        ["X-Bkapi-Debug"] = "true",
                                        foo = "bar",
                                    },
                                }
                            )
                        )
                    end
                )

                it(
                    "no debug info", function()
                        client_ip = "10.0.0.1"
                        request_headers = {
                            foo = "bar",
                        }
                        plugin.header_filter({}, ctx)

                        assert.stub(core.response.set_header).was_not_called()
                    end
                )
            end
        )
    end
)
