#!/bin/bash

while true
do
    # Check if ${BK_APIGW_NGINX_ERROR_LOG_SENTRY_DSN} is not empty
    if [[ -n "${BK_APIGW_NGINX_ERROR_LOG_SENTRY_DSN}" ]]; then
        # Check if sentrylogs process is running
        if pgrep -x "sentrylogs" > /dev/null
        then
            echo "sentrylogs is running"
        else
            echo "sentrylogs is not running, restarting..."
            SENTRY_DSN="${BK_APIGW_NGINX_ERROR_LOG_SENTRY_DSN}" NGINX_ERROR_PATH="/usr/local/apisix/logs/error.log" sentrylogs --daemonize
        fi
    fi
    sleep 60
done
