# syntax=docker/dockerfile:1

# Production image for Kamal. Ruby version pinned to .ruby-version.
ARG RUBY_VERSION=4.0.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /app

ENV RACK_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    MALLOC_ARENA_MAX="2"

# git: LedgerRepo shells out to it. ca-certificates: HTTPS to OpenAI, B2 and GitHub.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y git ca-certificates && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Throw-away stage: puma and nio4r compile native extensions.
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock .ruby-version ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache

FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY . .

# /data is the Kamal volume: ledger/ (git clone), jobs.jsonl, incoming/.
# A named volume copies this directory's ownership on first mount.
RUN groupadd --system app && useradd --system --gid app --create-home app && \
    mkdir -p /data && chown -R app:app /data /app
USER app

EXPOSE 9292
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb", "config.ru"]
