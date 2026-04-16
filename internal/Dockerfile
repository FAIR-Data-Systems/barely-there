FROM ruby:3.2-slim

# Install only build dependencies
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# === Gem caching layer ===
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3

# Copy application code
COPY . .

# Copy demo queries to a protected location (never mounted)
COPY sample_queries /demo-queries

# Copy entrypoint and fix line endings
COPY entrypoint.sh /entrypoint.sh

# Create the queries directory in the image with correct permissions
# (helps on first run, though the entrypoint will override)
RUN mkdir -p /queries && \
    chown -R "${UID:-1000}:${GID:-1000}" /queries 2>/dev/null || true

    
RUN sed -i 's/\r$//' /entrypoint.sh && \
    chmod +x /entrypoint.sh

# We will set the actual UID/GID at runtime via docker-compose (see below)
# For now, create a placeholder user
RUN groupadd -r severance && \
    useradd -r -u 1000 -g severance -d /app -s /sbin/nologin severance

ENTRYPOINT ["/entrypoint.sh"]   