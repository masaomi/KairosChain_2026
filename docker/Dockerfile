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

RUN groupadd -g 1000 kairos && useradd -u 1000 -g kairos -m -s /bin/sh kairos

# Copy entire gem environment from builder
COPY --from=builder /usr/local/bundle /usr/local/bundle

WORKDIR /app

# Copy SkillSet templates directly from source (more reliable than gem paths)
COPY KairosChain_mcp_server/templates/skillsets/ /app/skillset-sources/

# Build-time: initialize + install SkillSets into TEMPLATE directory
RUN kairos-chain init /app/.kairos-template && \
    kairos-chain skillset install /app/skillset-sources/mmp      --data-dir /app/.kairos-template && \
    kairos-chain skillset install /app/skillset-sources/hestia    --data-dir /app/.kairos-template && \
    kairos-chain skillset install /app/skillset-sources/synoptis  --data-dir /app/.kairos-template && \
    kairos-chain skillset install /app/skillset-sources/multiuser --data-dir /app/.kairos-template && \
    rm -rf /app/skillset-sources

RUN ruby -e "require 'pg'; puts 'pg OK'" && \
    ruby -e "require 'kairos_mcp'; puts 'kairos_mcp OK'" && \
    kairos-chain skillset list --data-dir /app/.kairos-template

RUN mkdir -p /app/.kairos /app/storage /app/keys && chown -R kairos:kairos /app/.kairos /app/.kairos-template /app/storage /app/keys

COPY docker/scripts/entrypoint.sh /usr/local/bin/
COPY docker/config/ /app/config-override/
RUN chmod +x /usr/local/bin/entrypoint.sh

USER kairos
ENV KAIROS_DATA_DIR=/app/.kairos
EXPOSE 8080

ENTRYPOINT ["entrypoint.sh"]
CMD ["kairos-chain", "--http", "--host", "0.0.0.0", "--port", "8080"]
