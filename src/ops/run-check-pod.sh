#!/bin/bash

run_stamp="$(date '+%Y%m%d-%H%M%S')"

./nginx-health-check.sh --mode pod --nginx-conf /usr/local/apisix/conf/nginx.conf --log-path /usr/local/apisix/logs/ --bundle-dir "$PWD/nginx-check-pod-${run_stamp}" --include-raw --delta-seconds 30
