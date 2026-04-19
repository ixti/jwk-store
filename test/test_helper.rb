# frozen_string_literal: true

require "minitest/autorun"
require "minitest/memory" if RUBY_ENGINE == "ruby"
require "minitest/strict"

require "jwk-store"

module Minitest
  class Test
    include Minitest::Memory if RUBY_ENGINE == "ruby"
  end
end
