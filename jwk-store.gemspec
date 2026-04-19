# frozen_string_literal: true

require_relative "./lib/jwk_store/version"

Gem::Specification.new do |spec|
  spec.name    = "jwk-store"
  spec.version = JWKStore::VERSION
  spec.authors = ["Alexey Zapparov"]
  spec.email   = ["alexey@zapparov.com"]

  spec.summary     = "TODO: Write a short summary, because RubyGems requires one."
  spec.description = "TODO: Write a longer description or delete this line."
  spec.homepage    = "https://github.com/ixti/jwk-store"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["source_code_uri"]       = "#{spec.homepage}/tree/v#{spec.version}"
  spec.metadata["bug_tracker_uri"]       = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"]         = "#{spec.homepage}/blob/v#{spec.version}/CHANGELOG.md"
  spec.metadata["documentation_uri"]     = "https://www.rubydoc.info/gems/jwk-store/#{spec.version}"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    extras = %w[LICENSE.txt README.md sig/jwk_store.rbs]

    ls.readlines("\x0", chomp: true).select { |f| f.start_with?("lib/") || extras.include?(f) }
  end

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "http", "~> 6.0"
  spec.add_dependency "jwt", "~> 3.0"
end
