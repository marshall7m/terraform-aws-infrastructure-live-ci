FROM python:3.9-alpine AS build

ARG TFENV_VERSION=2.2.2
# defaults to installing latest
ARG TGSWITCH_VERSION=""

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

WORKDIR /src/

COPY install.sh ./install.sh
COPY requirements.txt ./requirements.txt

RUN chmod u+x ./install.sh \
    && sh ./install.sh

FROM python:3.9-alpine

ARG TERRAFORM_VERSION=latest
ARG TERRAGRUNT_VERSION=latest

ENV VIRTUAL_ENV=/opt/venv
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /src/

COPY --from=build /usr/local /usr/local
COPY --from=build $VIRTUAL_ENV $VIRTUAL_ENV

ENV PATH="/usr/local/.tfenv/bin:$PATH"
# uses virtual env instead of system-wide packages
ENV PATH="$VIRTUAL_ENV/bin:$VIRTUAL_ENV/lib/python3.9/site-packages:$PATH"

RUN apk update \
    && apk add --virtual .runtime bash git openssl curl \
    && ln -sf python3 /usr/local/bin/python \
    && tfenv install ${TERRAFORM_VERSION} \
    && tfenv use ${TERRAFORM_VERSION} \
    && tgswitch ${TERRAGRUNT_VERSION}

COPY entrypoint.sh /tmp/entrypoint.sh

ENTRYPOINT ["bash", "/tmp/entrypoint.sh"]