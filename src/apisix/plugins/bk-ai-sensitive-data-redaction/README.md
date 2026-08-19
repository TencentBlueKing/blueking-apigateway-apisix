# bk-ai-sensitive-data-redaction

## English

### Overview and ordering

`bk-ai-sensitive-data-redaction` sends the finalized provider-specific AI JSON
request to a redaction service, installs the service-returned body as the LLM
request after contract validation, and restores exact known placeholders in the
client response. Its access phase only validates configuration and request
metadata and registers a request-local final-body filter; it performs no
third-party I/O. The filter runs after protocol conversion, provider options,
overrides, and model removal, immediately before signing and transport. The
redaction service receives the original request values. The plugin relies on
that trusted service to identify and replace every sensitive value; it cannot
prove that the returned body is completely redacted.

The plugin name is `bk-ai-sensitive-data-redaction` and its priority is `1039`.
APISIX executes higher priorities first, so it runs after `ai-proxy-multi`
(`1041`) or `ai-proxy` (`1040`) has selected an AI instance and detected the
client protocol, and before `ai-rate-limiting` (`1030`). Bind this plugin only
to a route that also uses `ai-proxy` or `ai-proxy-multi`.

### Configuration

| Field | Type | Required | Default | Validation and behavior |
| --- | --- | --- | --- | --- |
| `endpoint` | string | yes | none | Absolute `http://` or `https://` URL with a non-empty host. Control characters and whitespace are rejected. This is trusted administrator configuration; no SSRF or private-address deny list is applied. |
| `auth_header` | string | no | `Authorization` | Non-empty valid HTTP header name. `connection`, `content-length`, `content-type`, `host`, `keep-alive`, `proxy-authenticate`, `proxy-authorization`, `te`, `trailer`, `trailers`, `transfer-encoding`, and `upgrade` are forbidden, case-insensitively. |
| `auth_value` | string | no | none | Non-empty credential placed in `auth_header`. It is in `encrypt_fields` and may be a resolvable APISIX secret reference. The runtime value must contain no control bytes. No authentication header is sent when omitted. |
| `session_id_header` | string | no | `X-AI-Session-Id` | Non-empty valid HTTP header name used to read the optional session UUID. |
| `timeout` | integer | no | `3000` | Redaction-service connect/request/read timeout in milliseconds, from `1` through `60000`. |
| `ssl_verify` | boolean | no | `true` | Verifies the redaction-service TLS certificate. |
| `keepalive` | boolean | no | `true` | Reuses the redaction-service connection. |
| `keepalive_pool` | integer | no | `30` | Connection pool size; minimum `1`. |
| `keepalive_timeout` | integer | no | `60000` | Keepalive timeout in milliseconds; minimum `1000`. |
| `max_request_body_bytes` | integer | no | `1048576` | Maximum encoded original request body and maximum encoded masked body; minimum `1`. |
| `max_mapping_entries` | integer | no | `1000` | Maximum number of replacement entries; minimum `1`. |
| `max_mapping_bytes` | integer | no | `1048576` | Maximum sum, in bytes, of every placeholder and original value; minimum `1`. |

There is no fail-open option.

### Route and request example

The following is an executable Admin API template. Replace the example LLM and
redaction endpoints and the test LLM token for the target environment. It
contains no production credential.

```bash
export APISIX_ADMIN_KEY='replace-with-local-admin-key'

curl --fail-with-body -X PUT \
  'http://127.0.0.1:9180/apisix/admin/routes/ai-redaction-demo' \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{
    "uri": "/ai/redacted-chat",
    "methods": ["POST"],
    "plugins": {
      "request-id": {
        "header_name": "X-Request-ID",
        "include_in_response": false,
        "algorithm": "uuid"
      },
      "ai-proxy": {
        "provider": "openai",
        "auth": {
          "header": {"Authorization": "Bearer replace-with-llm-token"}
        },
        "options": {"model": "gpt-4o"},
        "override": {"endpoint": "https://llm.example.internal/v1/chat/completions"}
      },
      "bk-ai-sensitive-data-redaction": {
        "endpoint": "https://redactor.example.internal/v1/redact",
        "session_id_header": "X-AI-Session-Id"
      }
    }
  }'
```

Call the configured route with a canonical UUID session ID when conversation
correlation is required. The session header is optional.

```bash
curl --fail-with-body -X POST \
  'http://127.0.0.1:9080/ai/redacted-chat' \
  -H 'Content-Type: application/json' \
  -H 'X-AI-Session-Id: 24395b38-bf3f-426c-a632-10df20ec69c8' \
  -d '{
    "model": "gpt-4o",
    "stream": false,
    "messages": [
      {"role": "user", "content": "phone: 13800138000"}
    ]
  }'
```

### Request identity and third-party contract

`request_id` is mandatory in the third-party payload and is scoped to one HTTP
request. The plugin uses the first value with the canonical UUID shape
`8-4-4-4-12` hexadecimal digits, case-insensitively, in this order:

1. `ctx.var.apisix_request_id`;
2. `ctx.var.bk_request_id`;
3. a newly generated UUID v4.

The selected value must be unique for every HTTP request. The plugin validates
its shape but cannot detect a UUID that an upstream request-ID source wrongly
reuses across requests.

The placeholder namespace is derived only from that request ID: remove its
hyphens, lowercase its 32 hexadecimal digits, and wrap them as
`__BK_REDACT_<32-hex>_`. For example,
`da584df5-7bd5-4590-98e0-8f92a89f9494` produces
`__BK_REDACT_da584df57bd5459098e08f92a89f9494_`.

`session_id` is optional. A non-empty value from `session_id_header` must have
the same canonical UUID shape or the request is rejected with HTTP 400. If the
header occurs multiple times, its first value is used. It is forwarded only for
third-party/Agent conversation correlation. It is never an APISIX storage key
and never selects or persists a mapping. Reusing one session ID across multiple
turns does not persist or reuse replacements: every HTTP request has independent
stream state, while its placeholders are namespaced by the unique `request_id`.
There is no request-ID- or session-ID-keyed mapping lookup table. Conversation
history sent on a later turn is redacted again.

For each finalized provider attempt, APISIX makes one `POST` to the configured
endpoint with `Content-Type: application/json`. It does not retry a failed
redaction-service connection or request. An `ai-proxy-multi` fallback attempt
finalizes and redacts its own provider body; before every attempt the previous
attempt's mapping is cleared, and only the successful final attempt's mapping
can restore that attempt's response. A redaction failure is non-retryable: it
prevents the current LLM call and does not fall back to another LLM provider.
APISIX adds `auth_header: auth_value` only when `auth_value` is configured, and
omits `session_id` when the caller did not supply it.

`body` is a raw JSON string inside the JSON envelope, not a nested object. This
keeps the provider serializer's exact numeric lexemes, including large integers,
`-0`, and exponent spellings, across the redaction-service round trip.

```json
{
  "request_id": "da584df5-7bd5-4590-98e0-8f92a89f9494",
  "session_id": "24395b38-bf3f-426c-a632-10df20ec69c8",
  "placeholder_namespace": "__BK_REDACT_da584df57bd5459098e08f92a89f9494_",
  "body": "{\"model\":\"gpt-4o\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"phone: 13800138000\"}]}"
}
```

The service must return HTTP 200 with one JSON object in this form:

```json
{
  "body": "{\"model\":\"gpt-4o\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"phone: __BK_REDACT_da584df57bd5459098e08f92a89f9494_1__\"}]}",
  "replacements": [
    {
      "placeholder": "__BK_REDACT_da584df57bd5459098e08f92a89f9494_1__",
      "original": "13800138000"
    }
  ]
}
```

Before changing the LLM request, the plugin verifies all of these conditions:

- the top-level response is a JSON object and `body` is a raw JSON string that
  decodes to an object;
- the decoded `body` is detected as the same AI target protocol as the finalized
  provider body;
- `model` and `stream` are unchanged;
- `replacements` is a JSON array with at most `max_mapping_entries` entries;
- every entry is an object containing string `placeholder` and `original`
  values;
- every placeholder is unique and exactly matches
  `^<placeholder_namespace>[1-9][0-9]*__$`;
- every declared placeholder occurs in the masked raw JSON string;
- the sum of placeholder and original string bytes is no greater than
  `max_mapping_bytes`; and
- the masked raw JSON string is no greater than `max_request_body_bytes`;
- restoring `replacements` reconstructs the finalized provider request: JSON
  whitespace and equivalent string-escape spellings may differ, but object and
  array order and shape, literals, numeric lexemes, and all non-redacted semantic
  string content must match exactly.

These checks establish response shape and mapping consistency, not redaction
completeness. In particular, an unchanged `body` with an empty `replacements`
array satisfies the contract. The redaction service is therefore inside the
security trust boundary: if it misses a sensitive value, that value can be sent
to the LLM.

The finalized original and masked raw AI bodies are each limited by
`max_request_body_bytes`; an oversized original is HTTP 413, while an oversized
masked body is a third-party contract failure (HTTP 502). The full outbound
third-party request envelope has no separate schema limit. The third-party
response wire body is read with this implementation limit:

```text
min(29 + 6 * max_request_body_bytes
       + 6 * max_mapping_bytes
       + 33 * max_mapping_entries,
    64 MiB)
```

An over-limit `Content-Length` is rejected before reading, and chunked or
undeclared bodies are bounded while reading. These multipliers cover the
worst-case JSON escaping and mapping envelope; the decoded mapping limits above
are still validated separately. The same ceiling limits each non-streaming
restored body. For each streaming filter invocation, it limits aggregate
restored-field bytes and each reconstructed JSON event. This bounds
placeholder-driven expansion, not unchanged SSE frames or framing overhead. If
the restoration limit is exceeded, the affected bytes remain masked.

### Response protocols and restoration

Non-streaming `ai_chat` responses are restored as complete client-format JSON.
Known placeholders are replaced in every string leaf. A string leaf that is
itself a complete JSON object or array is decoded, restored recursively, and
re-encoded, which supports tool/function argument JSON.

Streaming restoration supports only client-visible SSE for these client
protocols:

- `openai-chat`: `choices[*].delta.content`, `reasoning_content`, `refusal`,
  `function_call.arguments`, and `tool_calls[*].function.arguments`;
- `openai-responses`: the `.delta` and corresponding `.done` events for
  `response.output_text`, `response.reasoning_summary_text`, and
  `response.function_call_arguments`; output text is separated by
  `content_index`, reasoning summaries by `summary_index`, and all families by
  their item/output identity;
- `anthropic-messages`: `text_delta.text` and
  `input_json_delta.partial_json` in content-block delta events.

The processor preserves incomplete SSE frames and placeholder prefixes across
transport chunks. Text fields receive raw originals; JSON-fragment fields
receive JSON-escaped originals. A field-specific `.done` event first flushes
only that logical field's pending prefix, then independently restores the
complete value carried by the done event. Comment/keepalive frames, malformed
events, unknown event shapes, and fields outside the list above pass through
unchanged without additional restoration.

Retained streaming state is bounded to a 1 MiB incomplete raw SSE remainder,
1024 active partial logical fields, 64 KiB of aggregate pending placeholder-
prefix bytes, and 64 KiB of aggregate dynamic active-key/metadata bytes. A raw
remainder over 1 MiB is emitted unchanged and reset. If another state bound is
exceeded, or an unexpected restoration failure occurs, buffered and current
bytes remain masked, passthrough mode latches for subsequent chunks, and the
failure path deliberately emits no original value.

Raw client-visible Bedrock `bedrock-converse` AWS EventStream and arbitrary
passthrough streaming protocols are rejected with HTTP 400 before the redaction
service or LLM is called. The current checkout has no converter from Bedrock
AWS EventStream to one of the supported client-visible SSE protocols, so
streaming Bedrock is not currently supported. If such a converter is added in
the future and runs before this response hook, the architecture can restore its
converted OpenAI or Anthropic SSE output; that is a future conditional, not a
current capability.

A protocol terminal event finalizes and flushes pending processor state, but it
does not clear the request mapping. The mapping and other sensitive state are
cleared only when the response hook receives `eof=true`, when failure cleanup
runs, or when the request is disposed. Configured AI-proxy
`max_response_bytes` and `max_stream_duration_ms` exits run EOF finalization
before ending a non-disconnected stream, flushing partial masked prefixes and
clearing request-local sensitive state without fabricating a protocol terminal
event. If the client disconnects first, downstream writes have already failed,
so no EOF write is attempted; no remaining buffered response can be delivered,
and request disposal reclaims the state rather than persisting it.

### Failure, security, and observability

Request processing is fail closed. No LLM upstream call occurs on any of these
plugin failures:

- HTTP 400: invalid non-empty session UUID, unsupported streaming protocol, or
  invalid/unencodable request JSON;
- HTTP 413: original body exceeds `max_request_body_bytes`;
- HTTP 500: the required AI-proxy context is absent, or the runtime
  authentication configuration remains unresolved/unsafe; and
- HTTP 502: redaction-service connection/request/read failure, non-200 status,
  malformed or oversized response, changed protocol/model/stream or other
  non-redacted request content, invalid mapping, or oversized masked body.

Response-side restoration does not intentionally fetch or insert an unmasked
fallback. If complete JSON cannot be decoded or encoded, or the SSE restorer
fails, the plugin passes through the upstream bytes and any buffered placeholder
data; after an SSE restorer failure, remaining chunks stay in passthrough mode.
This preserves placeholders when the upstream honored the contract, but it
cannot guarantee that passthrough bytes contain no sensitive data if the
redaction service or upstream violated the contract. Earlier stream content
that was successfully restored may already have been emitted before a later
failure. Unknown, altered, or incomplete placeholders are never restored; a
pending incomplete placeholder is emitted unchanged at a terminal event or EOF
and counted as unresolved.

All mappings, namespaces, session IDs, and SSE buffers live only in the current
request context. The plugin does not use an Nginx shared dictionary, etcd,
Redis, files, or another cross-request store. On entry to the plugin's access
phase, request-payload logging is set to `{}` and remains empty through plugin
validation, lower-priority access, provider routing, and request-build failures.
It also remains empty after a contract-verified masked body is accepted. While
the final-body filter is active, body-bearing model options, LLM/request-body
overrides, and authentication values are suppressed from the relevant AI-proxy
logs; the original body, masked body, mapping, and session ID are not logged by
this path.

This is not a blanket promise that every provider option or override-derived
value is absent from logs. Standard AI-proxy transport logs may retain
endpoint-derived non-body metadata such as `scheme`, `host`, `port`, `path`, and
`ssl_server_name`. Operators must treat endpoint metadata as log-visible and
restrict log access accordingly. Operational restoration/connection failures
may also be logged with the non-secret `request_id` for correlation.

The implementation maintains request-context-only numeric counters
`ctx._ai_redaction_restored_count` and
`ctx._ai_redaction_unresolved_count`. They are not public metrics. The plugin
does not create a public response header for `request_id`; any such header is
owned by a separately configured request-ID plugin. The redaction request's
`request_id` is also retained in `ctx._ai_redaction_request_id` for local
correlation after sensitive mapping state is cleared.

Use HTTPS with `ssl_verify=true` in production, authenticate the redaction
service with a resolved secret rather than a literal credential, and authorize
it for the minimum required caller/tenant scope. The redaction service sees the
original sensitive values and controls which values reach the LLM; it must be
operated as a trusted data processor. APISIX validates the returned contract but
does not determine whether every sensitive value was removed. If
`ai-request-rewrite`, `ai-rag`, or external moderation plugins are also bound,
their services may receive or inspect raw data. When operators intend the
redaction service to be the sole external raw-data recipient, they must also
exclude or explicitly trust those services; this plugin cannot enforce that
route-wide property.

The configured `endpoint` is also inside the administrative trust boundary.
The plugin applies no SSRF or private-address deny list, so route-configuration
authority must be restricted to trusted administrators.

## 中文

### 概述与执行顺序

`bk-ai-sensitive-data-redaction` 将 provider 定制完成的最终 AI JSON 请求发送给
脱敏服务，在协议校验通过后把服务返回的 body 设置为 LLM 请求，并在客户端响应中
精确还原已知占位符。插件的 access 阶段只校验配置和请求元数据，并注册请求局部的
最终 body filter，不调用第三方服务。该 filter 在协议转换、provider options、
override 和 model 删除之后执行，紧邻签名与传输之前。脱敏服务会接收原始请求值。
插件信任该服务能够识别并替换全部敏感值，无法证明返回 body 已完整脱敏。

插件名为 `bk-ai-sensitive-data-redaction`，优先级为 `1039`。APISIX 按优先级
从高到低执行，因此本插件会在 `ai-proxy-multi`（`1041`）或 `ai-proxy`
（`1040`）完成 AI 实例选择和客户端协议识别后执行，并在
`ai-rate-limiting`（`1030`）之前执行。只能把本插件绑定到同时配置了
`ai-proxy` 或 `ai-proxy-multi` 的路由。

### 配置

| 字段 | 类型 | 必填 | 默认值 | 校验与行为 |
| --- | --- | --- | --- | --- |
| `endpoint` | string | 是 | 无 | 带非空主机名的绝对 `http://` 或 `https://` URL；拒绝控制字符和空白字符。这是受信任的管理员配置，插件不执行 SSRF 或私网地址拒绝检查。 |
| `auth_header` | string | 否 | `Authorization` | 非空且合法的 HTTP 请求头名。不区分大小写禁止 `connection`、`content-length`、`content-type`、`host`、`keep-alive`、`proxy-authenticate`、`proxy-authorization`、`te`、`trailer`、`trailers`、`transfer-encoding` 和 `upgrade`。 |
| `auth_value` | string | 否 | 无 | 写入 `auth_header` 的非空凭据。该字段位于 `encrypt_fields` 中，可使用能被 APISIX 解析的 secret 引用；运行时值不能包含控制字节。省略时不发送认证请求头。 |
| `session_id_header` | string | 否 | `X-AI-Session-Id` | 用于读取可选会话 UUID 的非空合法 HTTP 请求头名。 |
| `timeout` | integer | 否 | `3000` | 脱敏服务连接、请求和读取超时，单位毫秒，范围 `1` 到 `60000`。 |
| `ssl_verify` | boolean | 否 | `true` | 是否校验脱敏服务的 TLS 证书。 |
| `keepalive` | boolean | 否 | `true` | 是否复用脱敏服务连接。 |
| `keepalive_pool` | integer | 否 | `30` | 连接池大小，最小值 `1`。 |
| `keepalive_timeout` | integer | 否 | `60000` | 长连接超时时间，单位毫秒，最小值 `1000`。 |
| `max_request_body_bytes` | integer | 否 | `1048576` | 原始请求体编码后以及脱敏请求体编码后的最大字节数，最小值 `1`。 |
| `max_mapping_entries` | integer | 否 | `1000` | replacement 条目的最大数量，最小值 `1`。 |
| `max_mapping_bytes` | integer | 否 | `1048576` | 所有占位符与原始值的总字节数上限，最小值 `1`。 |

插件没有 fail-open 选项。

### 路由与请求示例

下面是可执行的 Admin API 模板。请把示例 LLM、脱敏服务地址和测试 LLM token
替换为目标环境的值；示例不包含生产凭据。

```bash
export APISIX_ADMIN_KEY='replace-with-local-admin-key'

curl --fail-with-body -X PUT \
  'http://127.0.0.1:9180/apisix/admin/routes/ai-redaction-demo' \
  -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{
    "uri": "/ai/redacted-chat",
    "methods": ["POST"],
    "plugins": {
      "request-id": {
        "header_name": "X-Request-ID",
        "include_in_response": false,
        "algorithm": "uuid"
      },
      "ai-proxy": {
        "provider": "openai",
        "auth": {
          "header": {"Authorization": "Bearer replace-with-llm-token"}
        },
        "options": {"model": "gpt-4o"},
        "override": {"endpoint": "https://llm.example.internal/v1/chat/completions"}
      },
      "bk-ai-sensitive-data-redaction": {
        "endpoint": "https://redactor.example.internal/v1/redact",
        "session_id_header": "X-AI-Session-Id"
      }
    }
  }'
```

需要关联 Agent 多轮会话时，请使用符合规范格式的 UUID 作为会话 ID 调用路由；
会话请求头是可选的。

```bash
curl --fail-with-body -X POST \
  'http://127.0.0.1:9080/ai/redacted-chat' \
  -H 'Content-Type: application/json' \
  -H 'X-AI-Session-Id: 24395b38-bf3f-426c-a632-10df20ec69c8' \
  -d '{
    "model": "gpt-4o",
    "stream": false,
    "messages": [
      {"role": "user", "content": "phone: 13800138000"}
    ]
  }'
```

### 请求身份与第三方协议

第三方请求中的 `request_id` 必填，其作用域是单个 HTTP 请求。插件会按以下顺序
选择第一个符合 `8-4-4-4-12` 十六进制格式（不区分大小写）的 UUID：

1. `ctx.var.apisix_request_id`；
2. `ctx.var.bk_request_id`；
3. 新生成的 UUID v4。

选中的值必须在每个 HTTP 请求中唯一。插件只校验 UUID 格式，无法识别上游
request-ID 来源是否错误地在多个请求间复用了同一个 UUID。

占位符命名空间只从该 request ID 派生：删除连字符，将 32 个十六进制字符转为
小写，再组成 `__BK_REDACT_<32-hex>_`。例如
`da584df5-7bd5-4590-98e0-8f92a89f9494` 会生成
`__BK_REDACT_da584df57bd5459098e08f92a89f9494_`。

`session_id` 可选。`session_id_header` 中的非空值必须符合相同 UUID 格式，否则
返回 HTTP 400；请求头重复出现时使用第一个值。它只用于第三方服务或 Agent 多轮
会话的关联，不会成为 APISIX 存储键，也不会用于选择或持久化 mapping。多轮复用
同一个 session ID 不会让 APISIX 持久化或复用 replacement：每个 HTTP 请求具有
独立的流状态，占位符则按唯一 `request_id` 划分命名空间；不存在以 request ID 或
session ID 为键的 mapping 查询表。后续轮次再次携带的会话历史会重新脱敏。

对于每次 provider body 最终定型的尝试，APISIX 都会使用
`Content-Type: application/json` 向配置的 endpoint 发起一次 `POST`，且不会重试
失败的脱敏服务连接或请求。`ai-proxy-multi` 的每次 LLM fallback 尝试会分别完成
provider body 定型和脱敏；每次尝试前都会清除上一次 mapping，只有最终成功尝试的
mapping 能还原该次响应。脱敏失败不可重试：它会阻止当前 LLM 调用，也不会继续
fallback 到其他 LLM provider。只有配置 `auth_value` 时才会增加
`auth_header: auth_value`；调用方没有提供会话 ID 时会省略 `session_id`。

`body` 是 JSON envelope 内的原始 JSON 字符串，而不是嵌套对象。这样能在脱敏服务
往返过程中保留 provider serializer 产生的精确数值词法形式，包括大整数、`-0`
和指数写法。

```json
{
  "request_id": "da584df5-7bd5-4590-98e0-8f92a89f9494",
  "session_id": "24395b38-bf3f-426c-a632-10df20ec69c8",
  "placeholder_namespace": "__BK_REDACT_da584df57bd5459098e08f92a89f9494_",
  "body": "{\"model\":\"gpt-4o\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"phone: 13800138000\"}]}"
}
```

服务必须返回 HTTP 200，响应体为以下 JSON 对象：

```json
{
  "body": "{\"model\":\"gpt-4o\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"phone: __BK_REDACT_da584df57bd5459098e08f92a89f9494_1__\"}]}",
  "replacements": [
    {
      "placeholder": "__BK_REDACT_da584df57bd5459098e08f92a89f9494_1__",
      "original": "13800138000"
    }
  ]
}
```

修改 LLM 请求前，插件会校验以下全部条件：

- 顶层响应是 JSON 对象，且 `body` 是能解码为对象的原始 JSON 字符串；
- 解码后的 `body` 被识别为与最终 provider body 相同的 AI 目标协议；
- `model` 和 `stream` 未改变；
- `replacements` 是 JSON 数组，条目数不超过 `max_mapping_entries`；
- 每个条目都是包含字符串 `placeholder` 和 `original` 的对象；
- 每个占位符唯一，并严格匹配
  `^<placeholder_namespace>[1-9][0-9]*__$`；
- 每个声明的占位符都出现在脱敏后的原始 JSON 字符串中；
- 占位符与原始值的字符串字节总数不超过 `max_mapping_bytes`；以及
- 脱敏后的原始 JSON 字符串不超过 `max_request_body_bytes`；
- 应用 `replacements` 后能重建最终 provider 请求：允许等价的 JSON 空白和字符串
  转义写法不同，但对象/数组的顺序与结构、literal、数值词法形式以及所有未脱敏的
  语义字符串内容必须完全一致。

这些校验只能确认响应结构和 mapping 一致性，不能确认脱敏完整性。例如，未修改的
`body` 加空 `replacements` 数组也符合协议。因此脱敏服务位于安全信任边界内：如果
它漏掉敏感值，该值可能被发送给 LLM。

最终原始和脱敏后的 AI 原始 body 都受 `max_request_body_bytes` 限制；原始 body
超限返回 HTTP 413，脱敏 body 超限属于第三方协议错误，返回 HTTP 502。完整的
第三方出站请求 envelope 没有独立的 schema 限制。第三方响应的 wire body 按以下
实现上限读取：

```text
min(29 + 6 * max_request_body_bytes
       + 6 * max_mapping_bytes
       + 33 * max_mapping_entries,
    64 MiB)
```

超限的 `Content-Length` 会在读取前被拒绝；chunked 或未声明长度的响应则在读取
过程中受限。这些倍数覆盖最坏情况的 JSON 转义和 mapping envelope；解码后仍会
单独执行上述 mapping 限制校验。同一上限也用于限制每次非流式 body 还原；对每次流式
filter 调用，它限制聚合的已还原字段字节数，并逐个限制重建后的 JSON 事件。这限制的
是占位符引起的扩张，不包括未修改的 SSE frame 或 framing 开销。还原超过该上限时，
受影响的字节保持脱敏状态。

### 响应协议与还原

非流式 `ai_chat` 响应按完整客户端格式 JSON 还原。插件会替换每个字符串叶子中的
已知占位符。若某个字符串叶子本身是完整 JSON 对象或数组，则会解码、递归还原并
重新编码，从而支持 tool/function 参数 JSON。

流式还原只支持以下客户端可见 SSE 协议：

- `openai-chat`：`choices[*].delta.content`、`reasoning_content`、`refusal`、
  `function_call.arguments` 和 `tool_calls[*].function.arguments`；
- `openai-responses`：`response.output_text`、
  `response.reasoning_summary_text` 和 `response.function_call_arguments` 的
  `.delta` 及对应 `.done` 事件；output text 按 `content_index` 区分，reasoning
  summary 按 `summary_index` 区分，所有类别还会按 item/output 身份区分；以及
- `anthropic-messages`：content-block delta 事件中的 `text_delta.text` 和
  `input_json_delta.partial_json`。

处理器会跨传输 chunk 保留不完整 SSE frame 和占位符前缀。文本字段写入原始值，
JSON fragment 字段写入经过 JSON 转义的原始值。字段对应的 `.done` 事件会先只
flush 该逻辑字段待处理的前缀，再独立还原 done 事件携带的完整值。注释/keepalive
frame、格式错误的事件、未知事件结构以及上述列表以外的字段均原样透传，不执行
额外还原。

保留的流状态上限分别为：1 MiB 的不完整原始 SSE remainder、1024 个活跃的局部
逻辑字段、64 KiB 的占位符待处理前缀总字节数，以及 64 KiB 的动态活跃 key/metadata
总字节数。原始 remainder 超过 1 MiB 时会原样输出并重置。若触发其他状态上限或
发生非预期还原失败，已缓冲和当前字节会保持脱敏状态，后续 chunk 锁定为 passthrough；
失败路径不会主动输出任何原始值。

客户端直接可见的 Bedrock `bedrock-converse` 原始 AWS EventStream 以及任意
passthrough 流式协议，会在调用脱敏服务和 LLM 之前以 HTTP 400 拒绝。若 Bedrock
AWS EventStream 需要转换成受支持的客户端可见 SSE，当前 checkout 并不存在此类
converter，因此目前不支持 Bedrock 流式响应。若将来新增 converter，并在本响应
hook 之前生成 OpenAI 或 Anthropic SSE，则该架构可以还原转换后的输出；这是未来
条件，不是当前能力。

协议终止事件只会 finalize 并 flush 待处理的 processor 状态，不会清除请求 mapping。
只有响应 hook 收到 `eof=true`、执行失败清理，或请求被销毁时，mapping 和其他敏感
状态才会清除。AI proxy 配置的 `max_response_bytes` 或
`max_stream_duration_ms` 触发退出时，会在结束未断开的流之前执行 EOF finalization，
flush 不完整的脱敏占位符前缀并清理请求局部敏感状态，但不会伪造协议终止事件。
客户端断开是例外：此时下游写入已经失败，因此不会再尝试 EOF 写入；剩余缓冲响应
无法发送，请求销毁会回收状态而不会持久化。

### 失败、安全与可观测性

请求处理采用 fail closed。发生以下任一本插件错误时都不会调用 LLM 上游：

- HTTP 400：非空 session UUID 无效、流式协议不受支持，或请求 JSON
  无效/无法编码；
- HTTP 413：原始 body 超过 `max_request_body_bytes`；
- HTTP 500：缺少必需的 AI proxy 上下文，或运行时认证配置仍未解析/不安全；以及
- HTTP 502：脱敏服务连接/请求/读取失败、返回非 200、响应格式错误或超限、修改了
  协议/model/stream 或其他未脱敏请求内容、mapping 无效，或脱敏 body 超限。

响应侧还原不会主动获取或插入未脱敏 fallback。完整 JSON 无法解码或编码，或 SSE
还原器失败时，插件会透传上游字节和已缓冲的占位符数据；SSE 还原器失败后，后续
chunk 保持 passthrough。如果上游遵守协议，这会保留占位符；但若脱敏服务或上游
违反协议，插件无法保证透传字节中不存在敏感数据。发生后续失败前，先前成功还原的
流式内容也可能已经发送。未知、被修改或不完整的占位符永远不会被还原；协议终止
事件或 EOF 到达时，待处理的不完整占位符会原样输出，并计入 unresolved 数量。

所有 mapping、命名空间、session ID 和 SSE buffer 只存在于当前请求上下文中。
插件不使用 Nginx shared dictionary、etcd、Redis、文件或其他跨请求存储。进入本
插件 access 阶段时，请求 payload 日志即被设置为 `{}`；在插件校验、较低优先级
access、provider 路由和请求构建失败期间均保持为空；通过协议校验的脱敏 body 被接受
后也继续保持为空。最终 body filter 生效时，相关 AI-proxy 日志会抑制包含 body 的 model
options、LLM/request-body override 和认证值；该路径不会记录原始 body、脱敏 body、
mapping 或 session ID。

这不代表日志中绝不会出现任何 provider option 或由 override 派生的值。标准
AI-proxy 传输日志仍可能保留 endpoint 派生的非 body 元数据，例如 `scheme`、`host`、
`port`、`path` 和 `ssl_server_name`。运维方必须把 endpoint 元数据视为日志可见信息，
并相应限制日志访问权限。还原/连接相关的运行错误也可能携带非秘密的 `request_id`
用于关联。

当前实现只在请求上下文内维护数值计数器
`ctx._ai_redaction_restored_count` 和
`ctx._ai_redaction_unresolved_count`，它们不是公开 metrics。本插件不会为
`request_id` 创建公开响应头；此类响应头由另行配置的 request-ID 插件负责。脱敏
请求使用的 `request_id` 也保留在 `ctx._ai_redaction_request_id` 中，使敏感 mapping
状态清理后仍可在本地关联。

生产环境应使用 HTTPS 和 `ssl_verify=true`，通过已解析的 secret 而不是字面量凭据
认证脱敏服务，并按调用方/租户授予最小权限。脱敏服务会看到原始敏感值并决定哪些值
进入 LLM，必须作为受信任的数据处理方运行。APISIX 会校验返回协议，但不会判断是否
删除了全部敏感值。如果路由还绑定了 `ai-request-rewrite`、`ai-rag` 或外部
moderation 插件，它们的服务也可能接收或检查原始数据。当运维方要求脱敏服务成为
唯一接收原始数据的外部组件时，还必须排除或明确信任这些服务；本插件无法强制保证
整个路由都满足该属性。

配置的 `endpoint` 同样位于管理员信任边界内。插件不执行 SSRF 或私网地址拒绝检查，
因此必须把路由配置权限限制给受信任的管理员。
