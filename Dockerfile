# syntax=docker/dockerfile:1
ARG NODE_VERSION=18

################################ Stage: frontend-builder (build frontend assets)
FROM node:18 AS frontend-builder
ENV BUILD_NO_SERVER=true \
    BUILD_NO_HASH=true \
    BUILD_NO_CHUNKS=true \
    BUILD_MODULE=true \
    YARN_CACHE_FOLDER=/root/web/.yarn \
    NODE_ENV=production

WORKDIR /label-studio/web

# Fix Docker Arm64 Build
RUN yarn config set registry https://registry.npmjs.org/
RUN yarn config set network-timeout 1200000 # HTTP timeout used when downloading packages, set to 20 minutes

COPY web/package.json .
COPY web/yarn.lock .
COPY web/tools tools
RUN --mount=type=cache,target=${YARN_CACHE_FOLDER},sharing=locked \
    yarn install --prefer-offline --no-progress --pure-lockfile --frozen-lockfile --ignore-engines --non-interactive --production=false

COPY web .
COPY pyproject.toml ../pyproject.toml
RUN --mount=type=cache,target=${YARN_CACHE_FOLDER},sharing=locked \
    --mount=type=bind,source=.git,target=../.git \
    yarn run build && yarn version:libs

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LS_DIR=/label-studio \
    HOME=/tmp \
    PIP_CACHE_DIR=$HOME/.cache \
    POETRY_CACHE_DIR=$HOME/.poetry-cache \
    POETRY_VIRTUALENVS_CREATE=false \
    DJANGO_SETTINGS_MODULE=core.settings.label_studio \
    LABEL_STUDIO_BASE_DATA_DIR=/label-studio/data \
    OPT_DIR=/opt/heartex/instance-data/etc \
    SETUPTOOLS_USE_DISTUTILS=stdlib

WORKDIR $LS_DIR

# install packages
RUN set -eux \
 && apt-get update \
 && apt-get install --no-install-recommends --no-install-suggests -y \
    build-essential postgresql-client libmysqlclient-dev mysql-client python3-pip python3-dev \
    git libxml2-dev libxslt-dev zlib1g-dev gnupg curl lsb-release libpq-dev dnsutils vim && \
    apt-get purge --assume-yes --auto-remove --option APT::AutoRemove::RecommendsImportant=false \
     --option APT::AutoRemove::SuggestsImportant=false && rm -rf /var/lib/apt/lists/* /tmp/*

RUN --mount=type=cache,target=$PIP_CACHE_DIR,uid=1001,gid=0 \
    pip3 install --upgrade pip setuptools && pip3 install poetry uwsgi uwsgitop

# incapsulate nginx install & configure to a single layer
RUN set -eux; \
    curl -sSL https://nginx.org/keys/nginx_signing.key | apt-key add - && \
    echo "deb https://nginx.org/packages/mainline/ubuntu/ $(lsb_release -cs) nginx" >> /etc/apt/sources.list && \
    apt-get update && apt-get install -y nginx && \
    apt-get purge --assume-yes --auto-remove --option APT::AutoRemove::RecommendsImportant=false \
     --option APT::AutoRemove::SuggestsImportant=false && rm -rf /var/lib/apt/lists/* /tmp/* && \
    nginx -v

COPY --chown=1001:0 deploy/default.conf /etc/nginx/nginx.conf

RUN set -eux; \
    mkdir -p $OPT_DIR /var/log/nginx /var/cache/nginx /etc/nginx && \
    chown -R 1001:0 $OPT_DIR /var/log/nginx /var/cache/nginx /etc/nginx

# Copy essential files for installing Label Studio and its dependencies
COPY --chown=1001:0 pyproject.toml .
COPY --chown=1001:0 poetry.lock .
COPY --chown=1001:0 README.md .
COPY --chown=1001:0 label_studio/__init__.py ./label-studio/__init__.py

RUN mkdir -p /label-studio/data/test_data && \
    mkdir -p /label-studio/data/projects && \
    mkdir -p /label-studio/data/labeling_jobs && \
    chown -R 1001:0 /label-studio/data

COPY --chown=1001:0 LICENSE /label-studio/LICENSE
COPY --chown=1001:0 licenses /label-studio/licenses
COPY --chown=1001:0 label_studio /label-studio/label_studio
COPY --chown=1001:0 deploy /label-studio/deploy

# Ensure the poetry lockfile is up to date, then install all deps from it to
# the system python. This includes label-studio itself. For caching purposes,
# do this before copying the rest of the source code.
RUN --mount=type=cache,target=$POETRY_CACHE_DIR \
    poetry check --lock && poetry install

COPY --chown=1001:0 --from=frontend-builder /label-studio/web/dist $LS_DIR/web/dist

RUN python3 label_studio/manage.py collectstatic --no-input && \
    chown -R 1001:0 $LS_DIR && \
    chmod -R 755 $LS_DIR

ENV HOME=$LS_DIR

EXPOSE 8080

USER root

ENTRYPOINT ["./deploy/docker-entrypoint.sh"]
CMD ["label-studio"]
