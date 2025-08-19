--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2025 Tencent. All rights reserved.
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
local plugin = require("apisix.plugins.bk-response-check")
local exporter = require("apisix.plugins.prometheus.exporter")

describe(
    "bk-response-check", function()
        local prometheus

        before_each(
            function()
                stub(
                    ngx, "get_phase", function()
                        return "init"
                    end
                )

                exporter.http_init()
                prometheus = exporter.get_prometheus()
            end
        )

        after_each(
            function()
                ngx.get_phase:revert()
            end
        )

        context(
            "init", function()
                it(
                    "should initialize the metrics", function()
                        plugin.init()

                        assert.is_not_nil(prometheus.registry["apigateway_api_requests_total"])
                        assert.is_not_nil(prometheus.registry["apigateway_api_request_duration_milliseconds"])
                        assert.is_not_nil(prometheus.registry["apigateway_app_requests_total"])
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
                    "should set the headers", function()
                        ctx = {
                            var = {
                                bk_log_request_duration = 2000,
                                bk_log_upstream_duration = 1000,
                            }
                        }

                        plugin.header_filter(nil, ctx)

                        assert.stub(core.response.set_header).was_called_with("X-Bkapi-Total-Latency", 2000)
                        assert.stub(core.response.set_header).was_called_with("X-Bkapi-Upstream-Latency", 1000)

                    end
                )
            end
        )

        context(
            "log", function()
                it(
                    "should log the metrics", function()
                        ctx = {
                            var = {
                                api_name = "api_name",
                                stage_name = "stage_name",
                                resource_name = "resource_name",
                                status = 200,
                                proxy_phase = "proxy_phase",
                                proxy_error = "proxy_error",
                            },
                            curr_req_matched = {
                                _path = "matched_uri"
                            },
                        }
                        plugin.init()
                        plugin.log(nil, ctx)

                        assert.is_not_nil(prometheus.registry["apigateway_api_requests_total"])
                        assert.is_not_nil(prometheus.registry["apigateway_api_request_duration_milliseconds"])
                        assert.is_not_nil(prometheus.registry["apigateway_app_requests_total"])

                        local api_requests_total = prometheus.registry["apigateway_api_requests_total"]
                        local expected_label_names = {
                            'api_name',
                            'stage_name',
                            'resource_name',
                            'status',
                            'proxy_phase',
                            'proxy_error' ,
                        }
                        local expected_key = 'apigateway_api_requests_total{api_name="",stage_name="",' ..
                        'resource_name="",status="200",' ..
                        'proxy_phase="proxy_phase",proxy_error="proxy_error"}'

                        assert.is_same(expected_label_names, api_requests_total["label_names"])
                        assert.equal(expected_key, api_requests_total["_key_index"]["keys"][2])

                    end
                )
            end
        )



    end
)
