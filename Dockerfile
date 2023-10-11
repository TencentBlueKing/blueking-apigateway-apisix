ARG APISIX_VERSION="3.2.1"
FROM apache/apisix:$APISIX_VERSION-centos

WORKDIR /usr/local/apisix

# replace source
RUN mv /etc/yum.repos.d/CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo.backup && \
    curl -o /etc/yum.repos.d/CentOS-Base.repo http://mirrors.cloud.tencent.com/repo/centos7_base.repo && \
    yum clean all


# install tools
# you can add more tools for debug
# alreay on image: ifconfig nslookup ping dig ip ss route
RUN yum install -y wget unzip patch make sudo less iproute traceroute telnet lsof net-tools tcpdump mtr vim bind-utils && rm -rf /var/cache/yum
RUN curl -LJ https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o jq && chmod 755 jq && mv jq /usr/bin/jq

RUN mkdir -p /data/bkgateway/bin && rm -rf /usr/local/apisix/logs/*

RUN curl "https://bootstrap.pypa.io/pip/2.7/get-pip.py" -o "get-pip.py" && python get-pip.py && rm get-pip.py
RUN pip install sentrylogs

# install openresty & apisix
ARG APISIX_VERSION
RUN curl https://raw.githubusercontent.com/apache/apisix/${APISIX_VERSION}/utils/linux-install-luarocks.sh | bash
RUN luarocks install multipart --tree=/usr/local/apisix/deps && \
    rm -rf /root/.cache/luarocks/ || echo "no /root/.cache/luarocks to clean"

ADD ./build/config-watcher ./src/build/bin/apisix-start.sh ./src/build/bin/config-watcher-start.sh ./src/build/bin/sentrylogs-daemonize.sh /data/bkgateway/bin/
ADD ./src/apisix/plugins/ /usr/local/apisix/apisix/plugins/
# FIXME: remove the patch if upgrade to >=3.4.x, while the patch is only for 3.2.x ---
ADD ./src/build/patches /usr/local/apisix/patches
RUN ls /usr/local/apisix/patches | sort | xargs -L1 -I __patch_file__ sh -c 'cat ./patches/__patch_file__ | patch -t -p1'
# FIXME: remove the patch if upgrade to >=3.4.x, while the patch is only for 3.2.x ---

RUN chmod 755 /data/bkgateway/bin/* && chmod 777 /usr/local/apisix/logs


CMD ["sh", "-c", "/usr/bin/apisix init && /usr/bin/apisix init_etcd && /usr/local/openresty/bin/openresty -p /usr/local/apisix -g 'daemon off;'"]
