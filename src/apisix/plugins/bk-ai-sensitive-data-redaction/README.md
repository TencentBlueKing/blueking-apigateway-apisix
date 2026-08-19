# bk-ai-sensitive-data-redaction

## English

### Overview and ordering

`bk-ai-sensitive-data-redaction` sends the final AI JSON request to a redaction
service, installs the service-returned body as the LLM request after contract
validation, and restores exact known placeholders in the client response. The
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
| `endpoint` | string | yes | none | Absolute `http://` or `https://` URL with a non-empty host. Control characters and whitespace are rejected. |
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
the same canonical UUID shape or the request is rejected with HTTP 400. It is
forwarded only for third-party/Agent conversation correlation. It is never an
APISIX storage key and never selects a mapping. Reusing one session ID across
multiple turns does not persist or reuse replacements: every HTTP request has
an independent mapping and stream state stored only in its current request
context, while its placeholders are namespaced by the unique `request_id`.
There is no request-ID-keyed mapping lookup table. Conversation history sent on
a later turn is redacted again.

After request validation, APISIX makes one `POST` to the configured endpoint
with `Content-Type: application/json` (or makes one such attempt if connection
or request I/O fails). It adds `auth_header: auth_value` only when `auth_value`
is configured. `session_id` is omitted when the caller did not supply it.

```json
{
  "request_id": "da584df5-7bd5-4590-98e0-8f92a89f9494",
  "session_id": "24395b38-bf3f-426c-a632-10df20ec69c8",
  "placeholder_namespace": "__BK_REDACT_da584df57bd5459098e08f92a89f9494_",
  "body": {
    "model": "gpt-4o",
    "stream": true,
    "messages": [
      {"role": "user", "content": "phone: 13800138000"}
    ]
  }
}
```

The service must return HTTP 200 with one JSON object in this form:

```json
{
  "body": {
    "model": "gpt-4o",
    "stream": true,
    "messages": [
      {
        "role": "user",
        "content": "phone: __BK_REDACT_da584df57bd5459098e08f92a89f9494_1__"
      }
    ]
  },
  "replacements": [
    {
      "placeholder": "__BK_REDACT_da584df57bd5459098e08f92a89f9494_1__",
      "original": "13800138000"
    }
  ]
}
```

Before changing the LLM request, the plugin verifies all of these conditions:

- the top-level response and `body` are JSON objects, not arrays;
- `body` is detected as the same AI client protocol as the original body;
- `model` and `stream` are unchanged;
- `replacements` is a JSON array with at most `max_mapping_entries` entries;
- every entry is an object containing string `placeholder` and `original`
  values;
- every placeholder is unique and exactly matches
  `^<placeholder_namespace>[1-9][0-9]*__$`;
- every declared placeholder occurs in the compact JSON encoding of the masked
  body;
- the sum of placeholder and original string bytes is no greater than
  `max_mapping_bytes`; and
- the compact encoded masked body is no greater than
  `max_request_body_bytes`.

These checks establish response shape and mapping consistency, not redaction
completeness. In particular, an unchanged `body` with an empty `replacements`
array satisfies the contract. The redaction service is therefore inside the
security trust boundary: if it misses a sensitive value, that value can be sent
to the LLM.

The original and masked encoded AI bodies are each limited by
`max_request_body_bytes`; an oversized original is HTTP 413, while an oversized
masked body is a third-party contract failure (HTTP 502). The full outbound
third-party request envelope has no separate schema limit. The third-party
response wire body is read with this implementation limit:

```text
min(27 + 6 * max_request_body_bytes
       + 6 * max_mapping_bytes
       + 33 * max_mapping_entries,
    64 MiB)
```

An over-limit `Content-Length` is rejected before reading, and chunked or
undeclared bodies are bounded while reading. These multipliers cover the
worst-case JSON escaping and mapping envelope; the decoded mapping limits above
are still validated separately.

### Response protocols and restoration

Non-streaming `ai_chat` responses are restored as complete client-format JSON.
Known placeholders are replaced in every string leaf. A string leaf that is
itself a complete JSON object or array is decoded, restored recursively, and
re-encoded, which supports tool/function argument JSON.

Streaming restoration supports only client-visible SSE for these client
protocols:

- `openai-chat`: `choices[*].delta.content`, `reasoning_content`, `refusal`,
  `function_call.arguments`, and `tool_calls[*].function.arguments`;
- `openai-responses`: `response.output_text.delta`,
  `response.reasoning_summary_text.delta`, and
  `response.function_call_arguments.delta`; and
- `anthropic-messages`: `text_delta.text` and
  `input_json_delta.partial_json` in content-block delta events.

The processor preserves incomplete SSE frames and placeholder prefixes across
transport chunks. Text fields receive raw originals; JSON-fragment fields
receive JSON-escaped originals. Comment/keepalive frames, malformed events,
unknown event shapes, and fields outside the list above pass through unchanged
without additional restoration. An unterminated SSE remainder is bounded at
1 MiB; if it grows past that size before EOF, it is emitted unchanged and the
remainder buffer is reset rather than rejecting the response.

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
runs, or when the request is disposed. If the client disconnects first, the AI
streaming loop may stop before its EOF callback; no remaining buffered response
can be delivered, and the request-local state is reclaimed with the request
rather than persisted.

### Failure, security, and observability

Request processing is fail closed. No LLM upstream call occurs on any of these
plugin failures:

- HTTP 400: invalid non-empty session UUID, unsupported streaming protocol, or
  invalid/unencodable request JSON;
- HTTP 413: original body exceeds `max_request_body_bytes`;
- HTTP 500: the required AI-proxy context is absent, or the runtime
  authentication configuration remains unresolved/unsafe; and
- HTTP 502: redaction-service connection/request/read failure, non-200 status,
  malformed or oversized response, changed protocol/model/stream, invalid
  mapping, or oversized masked body.

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
Redis, files, or another cross-request store. Never log request/response bodies,
original values, placeholders/tokens, mappings, credentials, or `session_id`.
The implementation logs only operational restoration/connection failures and
may include the non-secret `request_id` for correlation.

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

## 中文

### 概述与执行顺序

`bk-ai-sensitive-data-redaction` 将最终 AI JSON 请求发送给脱敏服务，在协议校验
通过后把服务返回的 body 设置为 LLM 请求，并在客户端响应中精确还原已知占位符。
脱敏服务会接收原始请求值。插件信任该服务能够识别并替换全部敏感值，无法证明返回
body 已完整脱敏。

插件名为 `bk-ai-sensitive-data-redaction`，优先级为 `1039`。APISIX 按优先级
从高到低执行，因此本插件会在 `ai-proxy-multi`（`1041`）或 `ai-proxy`
（`1040`）完成 AI 实例选择和客户端协议识别后执行，并在
`ai-rate-limiting`（`1030`）之前执行。只能把本插件绑定到同时配置了
`ai-proxy` 或 `ai-proxy-multi` 的路由。

### 配置

| 字段 | 类型 | 必填 | 默认值 | 校验与行为 |
| --- | --- | --- | --- | --- |
| `endpoint` | string | 是 | 无 | 带非空主机名的绝对 `http://` 或 `https://` URL；拒绝控制字符和空白字符。 |
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
返回 HTTP 400。它只用于第三方服务或 Agent 多轮会话的关联，不会成为 APISIX
存储键，也不会用于选择 mapping。多轮复用同一个 session ID 不会让 APISIX 持久化
或复用 replacement：每个 HTTP 请求只在当前请求上下文中存储独立 mapping 和流
状态，占位符则按唯一 `request_id` 划分命名空间；不存在以 request ID 为键的
mapping 查询表。后续轮次再次携带的会话历史会重新脱敏。占位符还原始终绑定当前
HTTP 请求的 `request_id`，而不是 `session_id`。

请求校验通过后，APISIX 使用 `Content-Type: application/json` 向配置的 endpoint
发起一次 `POST`（若连接或请求 I/O 失败，则只尝试一次）。只有配置 `auth_value`
时才会增加 `auth_header: auth_value`。调用方没有提供会话 ID 时会省略
`session_id`。

```json
{
  "request_id": "da584df5-7bd5-4590-98e0-8f92a89f9494",
  "session_id": "24395b38-bf3f-426c-a632-10df20ec69c8",
  "placeholder_namespace": "__BK_REDACT_da584df57bd5459098e08f92a89f9494_",
  "body": {
    "model": "gpt-4o",
    "stream": true,
    "messages": [
      {"role": "user", "content": "phone: 13800138000"}
    ]
  }
}
```

服务必须返回 HTTP 200，响应体为以下 JSON 对象：

```json
{
  "body": {
    "model": "gpt-4o",
    "stream": true,
    "messages": [
      {
        "role": "user",
        "content": "phone: __BK_REDACT_da584df57bd5459098e08f92a89f9494_1__"
      }
    ]
  },
  "replacements": [
    {
      "placeholder": "__BK_REDACT_da584df57bd5459098e08f92a89f9494_1__",
      "original": "13800138000"
    }
  ]
}
```

修改 LLM 请求前，插件会校验以下全部条件：

- 顶层响应和 `body` 都是 JSON 对象，而不是数组；
- `body` 被识别为与原始 body 相同的 AI 客户端协议；
- `model` 和 `stream` 未改变；
- `replacements` 是 JSON 数组，条目数不超过 `max_mapping_entries`；
- 每个条目都是包含字符串 `placeholder` 和 `original` 的对象；
- 每个占位符唯一，并严格匹配
  `^<placeholder_namespace>[1-9][0-9]*__$`；
- 每个声明的占位符都出现在脱敏 body 的紧凑 JSON 编码中；
- 占位符与原始值的字符串字节总数不超过 `max_mapping_bytes`；以及
- 脱敏 body 的紧凑编码不超过 `max_request_body_bytes`。

这些校验只能确认响应结构和 mapping 一致性，不能确认脱敏完整性。例如，未修改的
`body` 加空 `replacements` 数组也符合协议。因此脱敏服务位于安全信任边界内：如果
它漏掉敏感值，该值可能被发送给 LLM。

原始和脱敏 AI body 编码后都受 `max_request_body_bytes` 限制；原始 body 超限
返回 HTTP 413，脱敏 body 超限属于第三方协议错误，返回 HTTP 502。完整的第三方
出站请求 envelope 没有独立的 schema 限制。第三方响应的 wire body 按以下实现上限
读取：

```text
min(27 + 6 * max_request_body_bytes
       + 6 * max_mapping_bytes
       + 33 * max_mapping_entries,
    64 MiB)
```

超限的 `Content-Length` 会在读取前被拒绝；chunked 或未声明长度的响应则在读取
过程中受限。这些倍数覆盖最坏情况的 JSON 转义和 mapping envelope；解码后仍会
单独执行上述 mapping 限制校验。

### 响应协议与还原

非流式 `ai_chat` 响应按完整客户端格式 JSON 还原。插件会替换每个字符串叶子中的
已知占位符。若某个字符串叶子本身是完整 JSON 对象或数组，则会解码、递归还原并
重新编码，从而支持 tool/function 参数 JSON。

流式还原只支持以下客户端可见 SSE 协议：

- `openai-chat`：`choices[*].delta.content`、`reasoning_content`、`refusal`、
  `function_call.arguments` 和 `tool_calls[*].function.arguments`；
- `openai-responses`：`response.output_text.delta`、
  `response.reasoning_summary_text.delta` 和
  `response.function_call_arguments.delta`；以及
- `anthropic-messages`：content-block delta 事件中的 `text_delta.text` 和
  `input_json_delta.partial_json`。

处理器会跨传输 chunk 保留不完整 SSE frame 和占位符前缀。文本字段写入原始值，
JSON fragment 字段写入经过 JSON 转义的原始值。注释/keepalive frame、格式错误的
事件、未知事件结构以及上述列表以外的字段均原样透传，不执行额外还原。未终止 SSE
remainder 的上限为 1 MiB；若它在 EOF 前超过该大小，插件会将其原样输出并重置
remainder buffer，而不是拒绝响应。

客户端直接可见的 Bedrock `bedrock-converse` 原始 AWS EventStream 以及任意
passthrough 流式协议，会在调用脱敏服务和 LLM 之前以 HTTP 400 拒绝。若 Bedrock
AWS EventStream 需要转换成受支持的客户端可见 SSE，当前 checkout 并不存在此类
converter，因此目前不支持 Bedrock 流式响应。若将来新增 converter，并在本响应
hook 之前生成 OpenAI 或 Anthropic SSE，则该架构可以还原转换后的输出；这是未来
条件，不是当前能力。

协议终止事件只会 finalize 并 flush 待处理的 processor 状态，不会清除请求 mapping。
只有响应 hook 收到 `eof=true`、执行失败清理，或请求被销毁时，mapping 和其他敏感
状态才会清除。若客户端提前断开，AI 流式循环可能在执行 EOF 回调前停止；此时剩余
缓冲响应已无法发送，请求局部状态会随请求回收，而不会被持久化。

### 失败、安全与可观测性

请求处理采用 fail closed。发生以下任一本插件错误时都不会调用 LLM 上游：

- HTTP 400：非空 session UUID 无效、流式协议不受支持，或请求 JSON
  无效/无法编码；
- HTTP 413：原始 body 超过 `max_request_body_bytes`；
- HTTP 500：缺少必需的 AI proxy 上下文，或运行时认证配置仍未解析/不安全；以及
- HTTP 502：脱敏服务连接/请求/读取失败、返回非 200、响应格式错误或超限、修改了
  协议/model/stream、mapping 无效，或脱敏 body 超限。

响应侧还原不会主动获取或插入未脱敏 fallback。完整 JSON 无法解码或编码，或 SSE
还原器失败时，插件会透传上游字节和已缓冲的占位符数据；SSE 还原器失败后，后续
chunk 保持 passthrough。如果上游遵守协议，这会保留占位符；但若脱敏服务或上游
违反协议，插件无法保证透传字节中不存在敏感数据。发生后续失败前，先前成功还原的
流式内容也可能已经发送。未知、被修改或不完整的占位符永远不会被还原；协议终止
事件或 EOF 到达时，待处理的不完整占位符会原样输出，并计入 unresolved 数量。

所有 mapping、命名空间、session ID 和 SSE buffer 只存在于当前请求上下文中。
插件不使用 Nginx shared dictionary、etcd、Redis、文件或其他跨请求存储。禁止记录
请求/响应 body、原始值、占位符/token、mapping、凭据或 `session_id`。当前实现只
记录还原/连接相关的运行错误，并可能携带非秘密的 `request_id` 用于关联。

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
