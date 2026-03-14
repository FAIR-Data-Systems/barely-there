FROM ruby:3.2-slim
RUN apt-get update && apt-get install -y --no-install-recommends build-essential && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY external/app.rb .
RUN gem install sinatra thin --no-document
VOLUME /data
CMD ["ruby", "app.rb"]
EXPOSE 4567
