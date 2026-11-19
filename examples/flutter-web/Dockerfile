# Template for the Flutter web frontend. Copy it to the frontend repo; keep FLUTTER_VERSION in sync
# with flutter-version in .github/workflows/ci.yml.
FROM debian:trixie-slim AS build
ARG FLUTTER_VERSION=3.47.8
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git unzip xz-utils \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home flutter
USER flutter
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git /home/flutter/sdk
ENV PATH="/home/flutter/sdk/bin:${PATH}"
RUN flutter config --no-analytics --enable-web && flutter precache --web

WORKDIR /home/flutter/app
COPY --chown=flutter:flutter pubspec.* ./
RUN flutter pub get
COPY --chown=flutter:flutter . .
RUN flutter build web --release

FROM nginxinc/nginx-unprivileged:1-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /home/flutter/app/build/web /usr/share/nginx/html
EXPOSE 8080
