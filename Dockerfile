FROM ruby:2.3

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 user

WORKDIR /usr/src/app

COPY Gemfile* ./
RUN chown user:user ./Gemfile*
USER user
RUN bundle install

COPY . .
USER root
RUN chown -R user:user .
USER user

CMD ["./bin/launch"]
