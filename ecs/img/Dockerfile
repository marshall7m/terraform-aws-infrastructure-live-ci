FROM python:3.9-slim-buster AS build

ARG TFENV_VERSION=2.2.2
# defaults to installing latest
ARG TGSWITCH_VERSION=""


ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

SHELL ["/bin/bash", "-c"]

WORKDIR /src/

COPY install.sh ./install.sh
COPY requirements.txt ./requirements.txt

RUN chmod u+x ./install.sh \
    && bash ./install.sh

FROM python:3.9-slim-buster

ARG TERRAFORM_VERSION=latest
ARG TERRAGRUNT_VERSION=latest

ENV VIRTUAL_ENV=/opt/venv
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

SHELL ["/bin/bash", "-c"]

WORKDIR /src/

COPY --from=build /usr/local /usr/local
COPY --from=build $VIRTUAL_ENV $VIRTUAL_ENV

ENV PATH="/usr/local/.tfenv/bin:$PATH"
# uses virtual env instead of system-wide packages
ENV PATH="$VIRTUAL_ENV/bin:$VIRTUAL_ENV/lib/python3.9/site-packages:$PATH"

RUN apt-get -y update \
    && apt-get install -y git openssl curl unzip jq \
    && ln -sf python3 /usr/local/bin/python \
    && tfenv install ${TERRAFORM_VERSION} \
    && tfenv use ${TERRAFORM_VERSION} \
    && if [[ "$TERRAGRUNT_VERSION" == "latest" ]]; then \
        curl -s https://warrensbox.github.io/terragunt-versions-list/ | jq -r '.Versions[0]' | xargs -I {} tgswitch {}; \
        else tgswitch "$TERRAGRUNT_VERSION"; fi

COPY entrypoint.sh /tmp/entrypoint.sh

ENTRYPOINT ["bash", "/tmp/entrypoint.sh"]