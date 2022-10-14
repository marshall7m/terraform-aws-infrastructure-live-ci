#!/bin/bash

# docker compose plugin
DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
mkdir -p "${DOCKER_CONFIG}"/cli-plugins
curl -s -SL https://github.com/docker/compose/releases/download/v2.3.3/docker-compose-linux-x86_64 -o "${DOCKER_CONFIG}"/cli-plugins/docker-compose
chmod +x "${DOCKER_CONFIG}"/cli-plugins/docker-compose