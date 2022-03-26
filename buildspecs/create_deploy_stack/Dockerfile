FROM python:3.9-alpine AS build

ARG TERRAFORM_VERSION
ARG TERRAGRUNT_VERSION

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

WORKDIR /src/

COPY install.sh ./install.sh
COPY requirements.txt ./requirements.txt

RUN chmod u+x ./install.sh \
    && sh ./install.sh

FROM python:3.9-alpine

ENV VIRTUAL_ENV=/opt/venv
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /src/

COPY --from=build /usr/local /usr/local
COPY --from=build $VIRTUAL_ENV $VIRTUAL_ENV

ENV PATH="$VIRTUAL_ENV/bin:$VIRTUAL_ENV/lib/python3.9/site-packages:$PATH"

RUN apk update \
    && apk add --virtual .runtime \
    bash \
    git \
    openssl \
&& ln -sf python3 /usr/local/bin/python