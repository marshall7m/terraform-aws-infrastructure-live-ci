#!/bin/bash

yarn install

docker-compose up --detach

docker-compose run testing /bin/bash