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

-- bk-response-check
--
-- This is a custom Apache APISIX plugin  that is responsible
-- for recording Prometheus metrics related to API requests and responses.
--
-- The plugin defines the following metrics:
-- 1. metric_api_requests_total: Records the number of processed HTTP requests,
--    partitioned by status code, method, and HTTP path.
-- 2. metric_api_request_duration: Records the time taken to process the requests,
--    partitioned by status code, method, and HTTP path.
-- 3. metric_app_requests_total: Records the number of HTTP requests per app_code/api/resource.


local core = require("apisix.core")
local exporter = require("apisix.plugins.prometheus.exporter")

---@type prometheus.Registry
local prometheus_registry

---@type prometheus.Counter
local metric_api_requests_total
---@type prometheus.Counter
local metric_app_requests_total

---@type prometheus.Histogram
local metric_api_request_duration

local X_BKAPI_TOTAL_LATENCY_HEADER = "X-Bkapi-Total-Latency"
local X_BKAPI_UPSTREAM_LATENCY_HEADER = "X-Bkapi-Upstream-Latency"

local schema = {}

---@type apisix.Plugin
local _M = {
    version = 0.1,
    priority = 153,
    name = "bk-response-check",
    schema = schema,
}


-- Initializes the plugin and its metrics.
function _M.init()
    prometheus_registry = exporter.get_prometheus()

    -- registers  metrics.
    metric_api_requests_total = prometheus_registry:counter(
        "apigateway_api_requests_total",
        "How many HTTP requests processed, partitioned by status code, method and HTTP path.", {
            "api_name",
            "stage_name",
            "resource_name",
            "status",
            "proxy_phase",
            "proxy_error",
        }
    )

    metric_api_request_duration = prometheus_registry:histogram(
        "apigateway_api_request_duration_milliseconds",
        "How long it took to process the request, partitioned by status code, method and HTTP path.", {
            "api_name",
            "stage_name",
            "resource_name",
        }, {
            100,
            300,
            1000,
            5000,
        }
    )

    metric_app_requests_total = prometheus_registry:counter(
        "apigateway_app_requests_total", "How many HTTP requests per app_code/api/resource.", {
            "app_code",
            "api_name",
            "stage_name",
            "resource_name",
        }
    )
end

---@param conf any
function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

---@param conf any
---@param ctx apisix.Context
function _M.header_filter(conf, ctx)
    -- X-Bkapi-Total-Latency  from bk_log_request_duration
    -- (equals to apisix request_time*1000 请求总耗时)
    core.response.set_header(X_BKAPI_TOTAL_LATENCY_HEADER, ctx.var.bk_log_request_duration)
    -- X-Bkapi-Upstream-Latency bk_log_upstream_duration
    -- (equals to apisix upstream_response_time * 1000 上游响应总秒数)
    core.response.set_header(X_BKAPI_UPSTREAM_LATENCY_HEADER, ctx.var.bk_log_upstream_duration)
end

---@param conf any
---@param ctx apisix.Context
function _M.log(conf, ctx)
    local api_name = ctx.var.bk_gateway_name or ""
    local stage_name = ctx.var.bk_stage_name or ""
    local resource_name = ctx.var.bk_resource_name or ""
    local proxy_phase = ctx.var.proxy_phase or ""
    local status = ctx.var.status
    local proxy_error = ctx.var.proxy_error or "0"

    -- 2023-10-18
    -- remove unused labels: service_name/method/matched_uri
    -- remove gateway=instance label, use cluster_id and namespace to identify the gateway instance

    -- TODO:
    -- 1. api_name to gateway_name
    -- 2. all *_name to *_id
    -- 3. make the name shorter `bk_apigateway_apigateway_api_request_duration_milliseconds_bucket`

    local status_label = ""
    if status then
        status_label = tostring(status)
    end

    metric_api_requests_total:inc(
        1, {
            api_name,
            stage_name,
            resource_name,
            status_label,
            proxy_phase,
            proxy_error,
        }
    )

    if ctx.var.request_time then
        metric_api_request_duration:observe(
            ctx.var.request_time * 1000, {
                api_name,
                stage_name,
                resource_name,
            }
        )
    end

    if ctx.var.bk_app_code then
        metric_app_requests_total:inc(
            1, {
                ctx.var.bk_app_code,
                api_name,
                stage_name,
                resource_name,
            }
        )
    end

end

return _M
