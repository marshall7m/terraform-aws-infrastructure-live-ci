FROM public.ecr.aws/bitnami/python:3.9.5 AS build

ARG TERRAFORM_VERSION=1.0.2
ARG TERRAGRUNT_VERSION=0.31.0
ARG TFLINT_VERSION=0.23.0
ARG TFSEC_VERSION=0.36.11
ARG TFDOCS_VERSION=0.10.1
ARG GIT_CHGLOG_VERSION=0.14.2
ARG SEMTAG_VERSION=0.1.1
ARG BATS_VERSION=1.4.1

ENV BUILD_PACKAGES="yarn wget unzip"
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

COPY install.sh /tmp/install.sh
COPY requirements.txt requirements.txt

RUN python3 -m venv $VIRTUAL_ENV \
    && chmod u+x /tmp/install.sh \
    && /tmp/install.sh

FROM public.ecr.aws/bitnami/python:3.9.5

COPY --from=build /usr/local/bin /usr/local/bin
COPY --from=build /opt/venv /opt/venv

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
ENV PATH="$VIRTUAL_ENV/lib/python3.9/site-packages:$PATH"

ENV RUNTIME_PACKAGES="bash git jq awscli pcregrep"
ENV HOME /opt/testing
WORKDIR $HOME

RUN apt-get update \
    && apt-get install -y --no-install-recommends $RUNTIME_PACKAGES \
    && git config --global advice.detachedHead false 

COPY scripts/ /opt/testing/scripts/