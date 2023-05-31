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

    end
)
