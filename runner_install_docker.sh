#!/bin/bash

apt-get -y update

apt-get install -y \
    software-properties-common build-essential \
    apt-transport-https ca-certificates gnupg lsb-release curl sudo

curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

sudo chmod u+x /usr/bin/*
sudo chmod u+x /usr/local/bin/*
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
sudo rm -rf /tmp/*