FROM alpine:3.13.6 AS build

ARG TERRAFORM_VERSION=1.0.2
ARG TERRAGRUNT_VERSION=0.31.0
ARG TFLINT_VERSION=0.23.0
ARG TFSEC_VERSION=0.36.11
ARG TFDOCS_VERSION=0.10.1
ARG GIT_CHGLOG_VERSION=0.14.2
ARG SEMTAG_VERSION=0.1.1

COPY install.sh /tmp/install.sh
COPY requirements.txt requirements.txt

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

RUN chmod u+x /tmp/install.sh \
    && sh /tmp/install.sh

# TODO: use smaller base img and install psql within build
FROM postgres:10.18-alpine

COPY --from=build /usr/local/bin /usr/local/bin
COPY --from=build /opt/venv /opt/venv

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
ENV PATH="$VIRTUAL_ENV/lib/python3.9/site-packages:$PATH"

# TODO: Figure out how to install apk packages to /usr/local/bin instead of usr/bin
# then mv runtime pkg to build stage
RUN apk add --virtual .runtime \
    bash \
    git \
    jq \
    # needed for bats --pretty formatter
    ncurses \
    openssl \
    grep \
&& git config --global advice.detachedHead false \
&& git config --global user.email testing_user@users.noreply.github.com \
&& git config --global user.name testing_user

WORKDIR /src/