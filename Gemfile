# frozen_string_literal: true

source "https://rubygems.org"
ruby RUBY_VERSION

gem "rake"

group :development do
  gem "debug", platform: :mri
end

group :test do
  gem "rubocop"
  gem "rubocop-minitest"
  gem "rubocop-performance"
  gem "rubocop-rake"

  gem "simplecov",      require: false
  gem "simplecov-lcov", require: false

  gem "minitest"
  gem "minitest-memory", platform: :mri
  gem "minitest-strict"

  gem "mutant-minitest"
end

group :sig do
  gem "rbs"
  gem "steep"
end

gemspec
