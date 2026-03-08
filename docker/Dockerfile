# =============================================================================
# KairosChain Meeting Place Server — Docker image
# Plan: log/kairoschain_meeting_place_server_docker_plan2.2_cursor_opus4.6_20260308.md
# =============================================================================

# Stage 1: Build — install gems with native extensions
FROM ruby:3.3-slim AS builder

RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY KairosChain_mcp_server/ ./gem-source/
RUN cd gem-source && \
    gem build kairos-chain.gemspec && \
    gem install --no-document kairos-chain-*.gem && \
    gem install --no-document puma rack pg

RUN ruby -e "require 'pg'; puts \"pg gem OK: libpq #{PG.library_version}\""

# =============================================================================
# Stage 2: Runtime — minimal image
# =============================================================================
FROM ruby:3.3-slim AS runtime

RUN apt-get update && apt-get install -y \
    libpq5 \
    postgresql-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN adduser --disabled-password --gecos "" --uid 1000 kairos

COPY --from=builder /usr/local/lib/ruby /usr/local/lib/ruby
COPY --from=builder /usr/local/bin/kairos-chain /usr/local/bin/
COPY --from=builder /usr/local/bin/kairos_mcp_server /usr/local/bin/
COPY --from=builder /usr/local/bin/puma /usr/local/bin/

WORKDIR /app

# Build-time: initialize + install SkillSets into TEMPLATE directory.
# The entrypoint copies this to the mounted volume on first start,
# avoiding the Docker named-volume masking problem.
RUN kairos-chain init /app/.kairos-template && \
    kairos-chain skillset install templates/skillsets/mmp      --data-dir /app/.kairos-template && \
    kairos-chain skillset install templates/skillsets/hestia    --data-dir /app/.kairos-template && \
    kairos-chain skillset install templates/skillsets/synoptis  --data-dir /app/.kairos-template && \
    kairos-chain skillset install templates/skillsets/multiuser --data-dir /app/.kairos-template

RUN ruby -e "require 'pg'; puts 'pg OK'" && \
    ruby -e "require 'kairos_mcp'; puts 'kairos_mcp OK'" && \
    kairos-chain skillset list --data-dir /app/.kairos-template

RUN mkdir -p /app/.kairos && chown -R kairos:kairos /app/.kairos /app/.kairos-template

COPY docker/scripts/entrypoint.sh /usr/local/bin/
COPY docker/config/ /app/config-override/
RUN chmod +x /usr/local/bin/entrypoint.sh

USER kairos
ENV KAIROS_DATA_DIR=/app/.kairos
EXPOSE 8080

ENTRYPOINT ["entrypoint.sh"]
CMD ["kairos-chain", "--http", "--host", "0.0.0.0", "--port", "8080"]
