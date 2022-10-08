FROM ghcr.io/marshall7m/terrace:v0.1.14
WORKDIR /tmp
COPY requirements.txt ./requirements.txt
RUN python3 -m pip install -r requirements.txt
WORKDIR /src