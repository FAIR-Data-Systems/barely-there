FROM ruby:3.2-slim

# Install build dependencies + runtime tools
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      gosu \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Create non-root user
RUN groupadd -r severance && \
    useradd -r -g severance -d /app -s /sbin/nologin -c "Docker app user" severance

# === Gem caching layer - Copy only dependency files first ===
COPY Gemfile Gemfile.lock ./

# Install gems (this layer caches well)
RUN bundle install --jobs 4 --retry 3

# Now copy the application code (this changes often)
COPY . .

# Copy queries directory (if it's not already included in the . above)
COPY queries /queries

# Switch to non-root user
USER severance

CMD ["ruby", "innie.rb"]