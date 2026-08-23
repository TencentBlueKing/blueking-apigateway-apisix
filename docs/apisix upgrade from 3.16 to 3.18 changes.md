# APISIX 3.16 直接升级到 3.18 评估

本文记录 BlueKing API Gateway 数据面从 Apache APISIX 3.16.0 直接升级到
3.18.0 的兼容性评估和实现结果。3.17 尚未发布，因此版本、镜像和文档中不保留
3.17 运行时基线。

评估日期：2026-08-24。

## 结论

代码和镜像升级可以进入评审及 CI 阶段。3.18 的全部本地补丁已在官方
`apache/apisix:3.18.0-redhat` 和生产 RPM 文件系统上以 `--fuzz=0` 重放；冲突的
Prometheus、DNS 502 补丁已基于 3.18 重做，Prometheus 过期 key 回收补丁已由上游
`nginx-lua-prometheus-api7 1.0.0-1` 取代。

上线判断仍需区分两层：

- 本仓库 PR 证明源码、补丁、插件测试和本地生产镜像成立；
- 发布流水线生成正式 `bk-apisix-oss:v3.18.0.1`、`bk-apisix:v3.18.0.1`
  后，必须按 digest 拉取两个镜像并重跑同一 smoke，才能宣布镜像提交完成。

## 3.16 到 3.18 的 breaking changes

以下项目来自 APISIX 3.17 和 3.18 changelog 中标记为不向后兼容的变更。只列出
与 BlueKing 数据面配置、鉴权、日志和 AI 链路直接相关的项目。

| 版本 | 变更 | 对 BlueKing 的影响 |
| --- | --- | --- |
| 3.17 | JWT 必填 claim、算法匹配和 key-auth anonymous fallback 更严格 | 需要在灰度中覆盖现有 consumer credential 和匿名 consumer |
| 3.17 | `/apisix/plugin/jwe/encrypt` 被移除 | 不得依赖 APISIX 侧生成 JWE；仅保留解密链路 |
| 3.17 | schema validate endpoint 要求 admin key | 调用方必须携带管理凭据 |
| 3.17 | hmac-auth 默认 `signed_headers=["date"]` | 未显式设置的旧客户端签名可能不兼容 |
| 3.17 | cas-auth 新增必填 `cookie.secret` | 启用该插件的配置需要迁移 |
| 3.17 | ai-rag、tencent-cloud-cls 的 `ssl_verify` 默认开启 | 自签名或私有 CA 环境需显式配置信任链，不能靠关闭验证兜底 |
| 3.17 | standalone 环境变量在 YAML 解析前替换 | 环境变量值的最终类型可能变化 |
| 3.18 | `Apisix-Plugins` debug header 改为按执行顺序输出 `name#phase` | 依赖旧 header 格式的诊断工具需要适配 |
| 3.18 | 约 19 个插件的请求/响应 body 默认限制为 64 MiB | 超限请求会被拒绝或截断，不再无限缓冲 |
| 3.18 | batch processor 默认 `max_pending_entries=8192` | logger 背压时会丢弃超出 backlog 的条目，需要监控丢弃量 |
| 3.18 | OpenID Connect 强制 audience、issuer、scope 并在 discovery 不可用时 fail closed | OIDC 配置错误会由宽松接受变为拒绝 |
| 3.18 | consumer 重复认证 key 被拒绝 | 需要在升级前清理重复 credential |
| 3.18 | `X-Forwarded-*` 变量和信任边界处理调整 | 必须验证 trusted_addresses 以及下游看到的 host/proto/port |
| 3.18 | sls-logger `ssl_verify` 默认 `true` | 私有日志端点证书链必须有效 |

此外，3.18 的 `limit-conn` 要求配置携带 `_meta.parent.resource_key`，用于确定
共享计数器的资源边界。`bk-concurrency-limit` 原先只把 plugin metadata 的
`value` 传给上游插件，导致 3.18 中 `increase()` 失败，并被 BlueKing 包装成 429。
本次改为调用上游 `plugin.set_plugins_meta_parent()` 建立父级关系，并新增 metadata
key/index 回归用例，保持原有 429/503 语义。

完整清单见 [APISIX CHANGELOG 3.18.0](https://github.com/apache/apisix/blob/3.18.0/CHANGELOG.md#3180)
和 [3.17.0](https://github.com/apache/apisix/blob/3.18.0/CHANGELOG.md#3170)。

## AI 相关变化与风险

### 3.17 引入的执行链变化

3.17 将 AI proxy 重构为 protocols/providers/transport 三层，并增加 OpenAI
Responses、Anthropic Messages、AWS Bedrock、passthrough 等协议能力。与现有
`ai-proxy`、`ai-proxy-multi` 最相关的运行时变化包括：

- AI cosocket 请求填充 `$upstream_*` 变量；这会改变 `bk-error-wrapper` 对
  provider 429、5xx、timeout 的错误分类和包装路径；
- provider timeout 由 500 改为 504；流式转换格式不匹配返回 502；
- 增加 `max_req_body_size`、`max_stream_duration_ms`、`max_response_bytes`、
  `max_retries`、`retry_on_failure_within_ms` 等保护项；
- 流式读取在客户端断开时中止，SSE 循环会主动让出调度；
- `ai-proxy-multi` 改进 DNS、健康检查和 fallback，并保持重试时的请求 body。

现有 BlueKing 配置使用的 `provider`、`auth`、`options.model`、
`override.endpoint`、`timeout`、`ssl_verify`、`logging`、`instances`、
`balancer`、`fallback_strategy` 在 3.18 schema 中仍存在。但上线前仍需用控制面
实际生成的 schema 和配置做端到端验证，尤其是流式/非流式 429、5xx、timeout
与 `bk-error-wrapper` 的组合。

### 3.18 新增和改变的 AI 能力

- `ai-proxy` 默认改用 `ngx_http_ffi_client`；可通过
  `plugin_attr.ai-proxy.http_client=lua-resty-http` 回退。生产 RPM 已验证编译
  `ngx_http_ffi_client-v0.1.3`，因此保持默认值。
- 新增 `ai-cache`，包含精确缓存、语义缓存和流式格式标记；本次升级只提供
  上游能力，不自动为现有路由启用。
- 新增 `ai-lakera-guard`，支持对非流式及流式响应扫描；本次升级不自动启用。
- `ai-proxy-multi` 新增 semantic load balancing；`ai-rate-limiting` 新增 Redis
  共享计数策略。
- AI cache 命中/未命中/bypass/embedding latency 进入 Prometheus；LLM summary
  增加观测变量；模型 label 会被截断以限制基数。
- `ai-aws-content-moderation` 的优先级、处理阶段、默认 deny code 和输入内容发生
  breaking change；`ai-aliyun-content-moderation` 默认只检查最近一轮 user role。

### Prometheus 官方指标开关

BlueKing 的 `plugin_attr.prometheus.official=false` 语义仍是只关闭 APISIX 官方
status、latency、bandwidth、LLM 指标，不能影响 BlueKing 自定义指标。本地
`001` 补丁只包围 3.18 已有的 metric write，不移动或改写上游的：

- `response_source` 和 disabled-label 处理；
- 模型 label 截断；
- LLM `type=total|ttft` 与 token distribution；
- AI cache 指标；
- Prometheus cache timer 刷新。

新增的 `bk-prometheus-official-metrics.t` 分别验证四类指标关闭时缺失、开启时
存在，并同时证明 BlueKing 自定义 metric 仍存在。

## 补丁重放台账

| 补丁 | 3.18 决策 | `--fuzz=0` 结果 | 回归覆盖 |
| --- | --- | --- | --- |
| `001_change_prometheus_default_buckets.patch` | 基于 3.18 exporter 重做 | 精确应用 | status/latency/bandwidth/LLM 与自定义指标 |
| `002_upstream_parse_domain_for_nodes.patch` | 保留 | offset +8，无 fuzz | 域名无有效 IP |
| `003_patch_no_valid_ip_found_502.patch` | 基于 3.18 `core.json.null` 重做 | 精确应用 | 502 和 BlueKing code `1650200` |
| `004_radixtree_uri_with_parameter_rebuild_with_interval.patch` | 保留 | 精确应用 | 路由重建现有全量用例 |
| `006_use_encoded_uri_for_radixtree_match.patch` | 基于 3.18 encoded-slash 开关重做 | 精确应用 | 中文编码路由和上游 `%2F` 14 场景 |
| `007_ngx_tpl_add_backlog.patch` | 保留 | offset +52，无 fuzz | 配置和全量 test-nginx |
| `008_log_rotate_file_logger_access_log.patch` | 保留 | 精确应用 | 上游 `plugin/log-rotate.t` |
| `009_prometheus_reclaim_expired_shared_dict_entries.patch` | 删除，上游已实现 | 不再应用 | 生产镜像 shared-dict 回收 smoke |

生产 Dockerfile 和 test-nginx runner 都使用
`patch --batch --forward --fuzz=0 -p1`，避免构建时静默接受模糊上下文。

原 006 会把 3.18 为 `match_uri_encoded_slash` 临时保留的 `%2F` 再编码为
`%252F`，上游 encoded-slash TEST 12 实际失败。重做后的补丁只在该开关启用时
保留 `%2F`，同时继续编码中文字符；移除 006 的对照运行会让 BlueKing 中文编码
路由用例从 `true` 变为 `nil`，因此不能直接删除该补丁。

## 生产镜像兼容性

- APISIX RPM：`3.18.0-0.ubi9.6`；
- APISIX Runtime：包含 `ngx_http_ffi_client-v0.1.3`；
- SAML：RPM 包含 `saml.so`，镜像显式安装 `libxslt`，并对 Nginx 与 `saml.so`
  分别执行 `ldd`，不得出现 `not found`；
- Prometheus：安装 `nginx-lua-prometheus-api7 1.0.0-1`，其
  `prometheus_keys.lua` 包含 `self.dict:flush_expired()`；
- shared dict：smoke 创建 1200 个带过期时间的 1 KiB metric 和 index key，
  从 4,157,440 字节降到 1,548,288 字节；过期并执行
  `remove_expired_keys()` 后恢复到 4,157,440 字节。

APISIX 3.18 同时将 `prometheus-metrics` 默认 shared dict 提高到 128 MiB。
这降低了正常基数下的内存压力，但不代替回收机制；因此镜像 gate 同时验证容量
回收和依赖源码，不能只 grep `flush_expired()`。

3.18 的 `core.request` 会把缓存中的请求头 key 统一为小写，且 APISIX Runtime C
模块的 header-modified 状态会跨同一 Busted worker 的测试用例保留。测试基建在
每个 case 结束时清理该状态；插件单测改为验证 `core.request.set_header` 的行为
边界，避免依赖内部缓存布局。

## 验证记录

实现阶段已通过：

```text
RUN_WITH_IT= make test-nginx CASE_FILE=bk-prometheus-official-metrics.t
  Files=2, Tests=15, Result: PASS
RUN_WITH_IT= make test-nginx CASE_FILE=bk-upstream-domain.t
  Files=2, Tests=9, Result: PASS
RUN_WITH_IT= make test-nginx CASE_FILE=bk-stage-context.t
  Files=2, Tests=21, Result: PASS
RUN_WITH_IT= make test-nginx CASE_FILE=bk-encoded-uri-route.t
  Files=2, Tests=6, Result: PASS
RUN_WITH_IT= make test-nginx CASE_FILE=router/radixtree-uri-with-parameter-encoded-slash.t
  Files=2, Tests=43, Result: PASS
RUN_WITH_IT= make test-nginx CASE_FILE=plugin/log-rotate.t
  Files=2, Tests=26, Result: PASS
bash -n src/ops/prometheus-expiry-smoke.sh
shellcheck src/ops/prometheus-expiry-smoke.sh
make apisix-image-smoke
  APISIX 3.18.0, FFI, libxslt/SAML, LuaRock 1.0.0-1,
  shared-dict reclaim, apisix init/test and image label: PASS
  连续运行两次，均回收 1,548,288 -> 4,157,440 字节
  本地镜像 ID: sha256:54ca286c300a0d8942da5372191c310a118bbc3ca1481a908b9b81840db11700
```

完整门禁结果：

```text
make edition-ee: PASS
make check-license: PASS
RUN_WITH_IT= make apisix-test-images: PASS
RUN_WITH_IT= make lint: 92 files, 0 warnings, 0 errors
RUN_WITH_IT= make test:
  Busted: 772 successes, 0 failures, 0 errors
  test-nginx: Files=33, Tests=742, Result: PASS
make apisix-image-smoke（连续两次）: PASS
```

## 发布与灰度要求

1. 使用控制面实际生成的 3.18 schema 和 AI 插件配置验证非流式、SSE、429、
   5xx、504、客户端断连和 fallback；核对 `bk-error-wrapper` body/header。
2. 灰度观察 logger backlog 丢弃、Prometheus shared dict free space、LLM label
   cardinality、AI TTFT/total latency、provider error 和 timeout 分类。
3. 正式镜像发布后记录两个镜像的不可变 digest，并重跑版本、FFI、SAML、
   Prometheus 回收、`apisix init`、`apisix test` 和完整插件 profile/schema dump。
4. 回滚只允许回到 3.16 配置合同；不要在混合运行期下发只被 3.18 接受的新字段。
