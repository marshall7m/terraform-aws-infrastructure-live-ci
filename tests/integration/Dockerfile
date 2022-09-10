FROM ghcr.io/marshall7m/terrace:v0.1.13
WORKDIR /tmp
COPY requirements.txt ./requirements.txt
COPY install.sh ./install.sh
RUN bash install.sh
WORKDIR /src