FROM ghcr.io/marshall7m/terrace:v0.1.11

COPY requirements.txt /tmp/pip-tmp/requirements.txt
RUN python3 -m pip install --upgrade pip \
    && python3 -m pip install --upgrade --disable-pip-version-check \
        --no-cache-dir -r /tmp/pip-tmp/requirements.txt