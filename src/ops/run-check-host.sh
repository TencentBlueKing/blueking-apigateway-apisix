#!/bin/bash

run_stamp="$(date '+%Y%m%d-%H%M%S')"

./nginx-health-check.sh --mode host --nginx-conf /etc/nginx/nginx.conf --log-path /var/log/nginx --bundle-dir "$PWD/nginx-check-host-${run_stamp}" --include-raw --delta-seconds 30
