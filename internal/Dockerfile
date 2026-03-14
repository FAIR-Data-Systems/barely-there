FROM ruby:3.3-slim
WORKDIR /app
COPY internal/internal.rb .
COPY queries /queries
CMD ["ruby", "internal.rb"]
