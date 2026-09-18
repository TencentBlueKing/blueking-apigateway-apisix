FROM tencentos/tencentos4-minimal:4.4-v20250922 AS apisix-runtime

ARG APISIX_VERSION=3.18.0
LABEL apisix_version="${APISIX_VERSION}"

# 1. yum install
COPY ./src/build/yum.repos.d/ /etc/yum.repos.d/
RUN sed -i 's/$releasever/9/g' /etc/yum.repos.d/apache-apisix.repo && sed -i 's/$releasever/8/g' /etc/yum.repos.d/openresty.repo
RUN yum clean packages
# you can add more tools for debug
# alreay on image: ifconfig nslookup dig ip ss route
# install openresty & apisix
RUN yum install -y apisix-${APISIX_VERSION} libxcrypt libxslt && \
    yum install -y tar m4 findutils procps less iproute traceroute telnet lsof net-tools tcpdump mtr vim bind-utils libyaml-devel hostname gawk iputils python3 python3-pip sudo && \
    yum install -y wget unzip patch make

# Keep existing dependency installation/cache separate from diagnostics packages.
# Exact TencentOS package; runtime use remains gated by diag-supported.json.
ARG DIAG_PERF_VERSION=6.6.119-52.7.tl4
RUN yum install -y --setopt=install_weak_deps=False perf-${DIAG_PERF_VERSION} && \
    yum clean all && rm -rf /var/cache/yum

# 2. install sentrylogs
RUN curl -LJ https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o jq && chmod 755 jq && mv jq /usr/bin/jq
RUN pip3 install sentrylogs

WORKDIR /usr/local/apisix

# 3. install luarocks and install lua libs
RUN wget https://raw.githubusercontent.com/apache/apisix/${APISIX_VERSION}/utils/linux-install-luarocks.sh && \
    bash linux-install-luarocks.sh && \
    rm linux-install-luarocks.sh
RUN luarocks install multipart --tree=/usr/local/apisix/deps && \
    rm -rf /root/.cache/luarocks/ || echo "no /root/.cache/luarocks to clean"


# 4. copy files and patch
RUN mkdir -p /data/bkgateway/bin && rm -rf /usr/local/apisix/logs/*

ADD ./src/build/bin/apisix-start.sh ./src/build/bin/sentrylogs-daemonize.sh /data/bkgateway/bin/
ADD ./src/apisix/plugins/ /usr/local/apisix/apisix/plugins/
ADD ./src/build/patches /usr/local/apisix/patches
RUN ls /usr/local/apisix/patches | sort | xargs -I __patch_file__ \
    sh -c 'patch --batch --forward --fuzz=0 -p1 < ./patches/__patch_file__'

RUN chmod 755 /data/bkgateway/bin/* && chmod 777 /usr/local/apisix/logs

ADD ./src/ops/nginx-health-check.sh ./src/ops/run-check-pod.sh /usr/local/apisix/ops/
RUN chmod 755 /usr/local/apisix/ops/*.sh

ARG DIAG_SOURCE_REVISION=unknown
COPY ./src/ops/apisix-diag ./src/ops/analyze-diag.py ./src/ops/diag-supported.json ./src/ops/diag-validation.md /usr/local/apisix/ops/
COPY ./src/ops/diag/ /usr/local/apisix/ops/diag/
COPY ./src/build/bin/build-diag-manifest.py /tmp/build-diag-manifest.py
RUN yum install -y --setopt=install_weak_deps=False binutils && \
    chmod 755 /usr/local/apisix/ops/apisix-diag && \
    ln -s /usr/local/apisix/ops/apisix-diag /usr/local/bin/apisix-diag && \
    PYTHONDONTWRITEBYTECODE=1 python3 /tmp/build-diag-manifest.py --revision "${DIAG_SOURCE_REVISION}" && \
    find /usr/local/apisix/ops/diag -type d -name __pycache__ -exec rm -rf {} + && \
    yum remove -y binutils && yum clean all && rm -rf /var/cache/yum

# 6. clean up
RUN yum remove -y wget unzip patch make && yum clean all && rm -rf /var/cache/yum && \
    PYTHONDONTWRITEBYTECODE=1 python3 /tmp/build-diag-manifest.py --finalize && \
    rm /tmp/build-diag-manifest.py

ENTRYPOINT ["/data/bkgateway/bin/apisix-start.sh"]

STOPSIGNAL SIGQUIT

# Optional export target. It copies exact image binaries/source, never rebuilds symbols.
FROM apisix-runtime AS diag-symbols
COPY ./src/build/bin/build-diag-manifest.py /tmp/build-diag-manifest.py
RUN PYTHONDONTWRITEBYTECODE=1 python3 /tmp/build-diag-manifest.py --symbols-out /diag-symbols && \
    rm /tmp/build-diag-manifest.py

FROM apisix-runtime AS final
