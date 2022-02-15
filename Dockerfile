FROM python:3.9-alpine AS build

ARG TERRAFORM_VERSION=1.0.2
ARG TERRAGRUNT_VERSION=0.31.0
ARG TFLINT_VERSION=0.23.0
ARG TFSEC_VERSION=0.36.11
ARG TFDOCS_VERSION=0.10.1
ARG GIT_CHGLOG_VERSION=0.14.2
ARG SEMTAG_VERSION=0.1.1
ARG GH_VERSION=2.2.0
ARG TFENV_VERSION=2.2.2

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
ENV PATH="/usr/local/.tfenv/bin:$PATH"

WORKDIR /src/

COPY --from=build /usr/local /usr/local
COPY --from=build $VIRTUAL_ENV $VIRTUAL_ENV

ENV PATH="$VIRTUAL_ENV/bin:$VIRTUAL_ENV/lib/python3.9/site-packages:$PATH"

RUN apk update \
    && apk add --virtual .runtime --no-cache \
    bash \
    git \
    curl \
    jq \
    # needed for bats --pretty formatter
    ncurses \
    openssl \
    grep \
    # needed for pcregrep
    pcre-tools \
    coreutils \
    postgresql-client \
    libgcc \
    libstdc++ \
    ncurses-libs \
    docker \
&& ln -sf python3 /usr/local/bin/python \
&& git config --global advice.detachedHead false \
&& git config --global user.email testing_user@users.noreply.github.com \
&& git config --global user.name testing_user 

COPY entrypoint.sh ./entrypoint.sh

ENTRYPOINT ["bash", "entrypoint.sh"]