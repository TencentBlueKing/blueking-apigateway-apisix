#!/usr/bin/env bash

set -euo pipefail

smoke_root="$(mktemp -d /tmp/apisix-prometheus-expiry.XXXXXX)"
nginx_conf="$smoke_root/nginx.conf"

cleanup() {
  openresty -p "$smoke_root/" -c "$nginx_conf" -s quit >/dev/null 2>&1 || true
  for _ in {1..20}; do
    if [ ! -e "$smoke_root/logs/nginx.pid" ]; then
      break
    fi
    sleep 0.05
  done
  rm -rf "$smoke_root"
}
trap cleanup EXIT

mkdir -p "$smoke_root/logs"
cat >"$nginx_conf" <<'EOF'
worker_processes 1;
error_log stderr notice;
pid logs/nginx.pid;

events {
    worker_connections 64;
}

http {
    lua_package_path "/usr/local/apisix/deps/share/lua/5.1/?.lua;;";
    lua_shared_dict prometheus-metrics 4m;

    server {
        listen 127.0.0.1:19090;

        location = /smoke {
            content_by_lua_block {
                local KeyIndex = require("prometheus_keys")
                local dict = ngx.shared["prometheus-metrics"]
                local index = KeyIndex.new(dict, "smoke_", 600)
                local baseline = dict:free_space()

                assert(dict:set("permanent", true))
                for i = 1, 1200 do
                    local key = "metric_" .. i
                    assert(dict:set(key, string.rep("x", 1024), 0.05))
                    assert(index:add(key, "unexpected LRU eviction", 0.05) == nil)
                end

                local allocated = dict:free_space()
                assert(allocated < baseline - 1048576,
                       "smoke did not allocate enough shared-dict memory")

                ngx.sleep(0.2)
                index:remove_expired_keys()

                local reclaimed = dict:free_space()
                assert(reclaimed >= baseline - 131072,
                       "expired entries were not reclaimed: baseline=" .. baseline ..
                       ", allocated=" .. allocated .. ", reclaimed=" .. reclaimed)
                ngx.say("prometheus expiry reclaimed shared-dict memory: baseline=", baseline,
                        ", allocated=", allocated, ", reclaimed=", reclaimed)
            }
        }
    }
}
EOF

openresty -p "$smoke_root/" -c "$nginx_conf"
curl --fail --silent --show-error http://127.0.0.1:19090/smoke
