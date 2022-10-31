FROM ghcr.io/marshall7m/terrace:v0.1.15
WORKDIR /workspace

COPY requirements.txt /tmp/deps/requirements.txt
COPY install.sh /tmp/deps/install.sh

RUN bash /tmp/deps/install.sh \ 
    && python3 -m pip install --upgrade pip \
    && python3 -m pip install --upgrade --disable-pip-version-check \
        --no-cache-dir -r /tmp/deps/requirements.txt