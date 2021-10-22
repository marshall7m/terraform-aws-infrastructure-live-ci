#!/bin/bash

yarn upgrade

docker-compose up --detach

docker-compose run testing /bin/bash