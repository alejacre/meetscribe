#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ruby <<'RUBY'
require "json"
require "pathname"
require "yaml"

Dir[".github/**/*.{yml,yaml}"].sort.each do |path|
  YAML.safe_load(File.read(path), aliases: true)
end

Dir["docs/**/*.json"].sort.each do |path|
  JSON.parse(File.read(path))
end

missing = []
Dir["**/*.md"].sort.each do |path|
  body = File.read(path)
  body.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten.each do |raw_target|
    target = raw_target.split("#", 2).first
    next if target.empty? || target.match?(/\A(?:https?:|mailto:)/)

    target = target.delete_prefix("<").delete_suffix(">")
    resolved = Pathname(path).dirname.join(target).cleanpath
    missing << "#{path}: #{raw_target}" unless resolved.exist?
  end
end

unless missing.empty?
  warn "Broken local Markdown links:"
  missing.each { |entry| warn "  #{entry}" }
  exit 1
end
RUBY

node scripts/check-site.mjs
git diff --check
echo "Documentation checks passed"
