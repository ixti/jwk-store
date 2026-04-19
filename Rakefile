# frozen_string_literal: true

require "bundler/gem_tasks"

require "minitest/test_task"
Minitest::TestTask.create do |t|
  t.libs << "test"
  t.test_globs = ["test/**/*_test.rb"]
  t.framework  = 'require "test_helper"'
end

require "rubocop/rake_task"
RuboCop::RakeTask.new

desc "Run mutation testing with Mutant"
task :mutant do
  system("bin/mutant", "run", "--since", "main") or abort("Mutant failed!")
end

desc "Type check with Steep"
task :steep do
  system("bin/steep", "check", "--log-level=error") or abort("Steep failed!")
end

task default: %i[test rubocop steep]
