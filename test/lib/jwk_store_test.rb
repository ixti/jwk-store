# frozen_string_literal: true

class JWKTestStore < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::JWKStore::VERSION
  end
end
