#!/usr/bin/env ruby
# frozen_string_literal: true

# SPDX-License-Identifier: AGPL-3.0-or-later
#
# overlays/<env>/sukhi.version の版とダイジェストを書き換える(手でも CI からも同じもの)。標準ライブラリだけ。
#   scripts/bump-version.rb prod 1.0.0       # リリースの版(semver)
#   scripts/bump-version.rb dev sha-abc1234  # main の sha
# 各 image のダイジェストを skopeo で解決する(multi-arch の一覧のダイジェストが返ること。未確認)。
# 1 つでも解決できなければ、何も書き換えない。署名の検証は scripts/check.rb(SUKHI_COSIGN=1)と、箱の同期スクリプトがやる。

require "open3"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = nil
Dir.chdir(File.expand_path("..", __dir__))

def die(msg)
  warn(msg)
  exit 1
end

env, ver = ARGV
die "usage: #{File.basename($PROGRAM_NAME)} <env> <version>" if env.nil? || ver.nil?
path = "overlays/#{env}/sukhi.version"
die "no #{path}" unless File.file?(path)
if env == "prod"
  die "prod needs a semver version" unless ver.match?(/\A\d+\.\d+\.\d+\z/)
else
  die "version must be semver or sha-<commit>" unless ver.match?(/\A(\d+\.\d+\.\d+|sha-[0-9a-f]{7,40})\z/)
end
owner = ENV.fetch("SUKHI_OWNER", "sukhi-social")

text = File.read(path)
names = text.scan(/^digest\.([A-Za-z0-9._-]+):/).flatten
die "no digest.* lines in #{path}" if names.empty?

# 先に全部解決する
digests = names.to_h do |n|
  begin
    out, st = Open3.capture2e("skopeo", "inspect", "--no-tags", "--format", "{{.Digest}}", "docker://ghcr.io/#{owner}/sukhi-fedi-#{n}:#{ver}")
  rescue Errno::ENOENT
    die "skopeo not found"
  end
  die "cannot resolve #{n}:#{ver}\n#{out}" unless st.success?
  d = out.strip
  die "unexpected digest for #{n}: #{d}" unless d.match?(/\Asha256:[0-9a-f]{64}\z/)
  [n, d]
end

text = text.sub(/^version:[ \t]*[^ \t#\n]*/) { "version: #{ver}" }
digests.each { |n, d| text = text.sub(/^(digest\.#{Regexp.escape(n)}:[ \t]*)sha256:[0-9a-f]{64}/) { "#{Regexp.last_match(1)}#{d}" } }
File.write(path, text)
puts "updated #{path}: version=#{ver}"
puts text.lines.grep(/\Adigest\./)
