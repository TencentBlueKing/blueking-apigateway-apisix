# src/build


- `bin/` the script for startup
- `patches/` the patches for apisix
    - 001_fix_failed_to_fetch_data_from_etcd.patch: https://github.com/apache/apisix/pull/8493
    - 010_quiet_not_found_handler_exit.patch: suppress the HTTP exit warning only when
      `bk-not-found-handler` returns its expected 404. Other plugin/status warnings and
      `_meta.error_response` handling are preserved. Applied to APISIX 3.18.0 by the
      production image build and the test-nginx runner.


