#!/bin/sh
echo "starting......"

# start nginx error to sentry
if [ x"${BK_APIGW_NGINX_ERROR_LOG_SENTRY_DSN}" != x"" ]
then
    echo "start sentrylogs to ship nginx error log to sentry"
    SENTRY_DSN="${BK_APIGW_NGINX_ERROR_LOG_SENTRY_DSN}" NGINX_ERROR_PATH="/usr/local/apisix/logs/error.log" sentrylogs --daemonize

    # start a daemon to check sentrylogs, the sentrylogs will only process the `tail` records, so it's safe to restart it
    sh /data/bkgateway/bin/sentrylogs-daemonize.sh &
fi


echo "start apisix"
/usr/bin/apisix init && /usr/bin/apisix init_etcd && /usr/local/openresty/bin/openresty -p /usr/local/apisix -g 'daemon off;'

echo "quit"
