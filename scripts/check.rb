#!/usr/bin/env ruby
# frozen_string_literal: true

# SPDX-License-Identifier: AGPL-3.0-or-later
#
# sukhi-infra の点検(CI と手元で同じものを回す)。何も変えない。標準ライブラリだけ。
#   scripts/check.rb                       # 構造・sukhi.version・Image= の形・秘密の混入
#   SUKHI_STRICT=1 scripts/check.rb        # 0 埋めの仮ダイジェストも失敗にする
#   SUKHI_SETUP=../sukhi-setup SUKHI_COSIGN=1 scripts/check.rb   # 埋めたあとの image に cosign verify(要 cosign)
# {{version}} / {{digest:*}} を埋めるのは sukhi-setup の bin/sukhi-render(埋め方の唯一の場所)。ここでは再実装しない。

require "fileutils"
require "json"
require "open3"
require "tmpdir"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = nil
Dir.chdir(File.expand_path("..", __dir__))

SIGNER_RE = '^https://github\.com/sukhi-social/sukhi-fedi/\.github/workflows/' \
            '(release\.yml@refs/tags/v.+|combined-sha\.yml@refs/heads/main)$'
ZERO = "sha256:#{'0' * 64}"
SUKHI_IMAGE = %r{\Aghcr\.io/sukhi-social/sukhi-fedi-([a-z0-9-]+):\{\{version\}\}@\{\{digest:([a-z0-9-]+)\}\}\z}.freeze
PINNED_IMAGE = %r{\A[^@{}]+:[^@:/{}]+@sha256:[0-9a-f]{64}\z}.freeze
SECRET_ENV = /\A(Environment|EnvironmentFile)=[A-Z_]*(SECRET|PASSWORD|TOKEN|PRIVATE_KEY|ERLANG_COOKIE)[A-Z_]*=/.freeze
PLACEHOLDER_DOMAIN = /\A(?:CHANGE-ME|example(?:\.invalid)?|localhost)(?:[.:]|$)/i.freeze
strict = ENV["SUKHI_STRICT"] == "1"
@failed = false

def err(msg)
  warn "error: #{msg}"
  @failed = true
end

def warn_(msg) = warn("warn: #{msg}")

def placeholder(msg, strict)
  strict ? err(msg) : warn_("#{msg}。同期スクリプトは適用しない")
end

def lines(file) = File.readlines(file, chomp: true)

def load_json(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  err("#{path}: JSON が不正: #{e.message}")
  nil
end

# 1. sukhi の image は {{version}} / {{digest:<name>}} の形だけ。ほかは <name>:<tag>@sha256:<64桁>。Image= は base にだけ。
Dir.glob("overlays/**/*").select { |f| File.file?(f) }.each do |f|
  err("#{f}: Image= は base/ の本体にだけ置く(overlay の Image= は版の manifest の外になる)") if lines(f).any? { |l| l.start_with?("Image=") }
end

names = []
Dir.glob("base/*.container").sort.each do |f|
  img = lines(f).find { |l| l.start_with?("Image=") }&.delete_prefix("Image=")
  if img.nil?
    err("#{f}: Image= がない")
  elsif (m = img.match(SUKHI_IMAGE))
    err("#{f}: image 名と {{digest:*}} の名前が違う: #{img}") unless m[1] == m[2]
    names << m[1]
  elsif img.start_with?("ghcr.io/sukhi-social/")
    err("#{f}: sukhi の image は ghcr.io/sukhi-social/sukhi-fedi-<name>:{{version}}@{{digest:<name>}} の形にする: #{img}")
  elsif img.match?(PINNED_IMAGE)
    placeholder("#{f}: 仮のダイジェスト(0 埋め)", strict) if img.end_with?("@#{ZERO}")
  else
    err("#{f}: Image= の形が違う: #{img}")
  end
end
names = names.uniq.sort

# 1b. instance.json is the non-secret runtime contract for sukhi-fedi.
instance_paths = ["base/instance.json"] + Dir.glob("overlays/*/instance.json").sort
# 箱の /etc/sukhi/instance.json は stow が stow/<env>/instance.json から張る。実体は overlay の一つだけ(写しを持たない)。
Dir.glob("overlays/*/instance.json").sort.each do |path|
  env = path.split("/")[1]
  link = "stow/#{env}/instance.json"
  want = "../../overlays/#{env}/instance.json"
  err("#{link}: #{want} への symlink にする") unless File.symlink?(link) && File.readlink(link) == want
end
frontend_units = Dir.glob("base/sukhi-web-*.container").map { |f| File.basename(f, ".container").delete_prefix("sukhi-") }.sort
instance_paths.each do |path|
  config = load_json(path)
  next unless config.is_a?(Hash)

  %w[version domain frontend upstreams routes site].each do |key|
    err("#{path}: #{key} がない") unless config.key?(key)
  end
  err("#{path}: version は 1") unless config["version"] == 1
  domain = config["domain"].to_s
  err("#{path}: domain が空") if domain.empty?
  err("#{path}: placeholder domain は使えない: #{domain}") if domain.match?(PLACEHOLDER_DOMAIN)

  frontend = config["frontend"].to_s
  err("#{path}: frontend が存在しない unit を指している: #{frontend}") unless frontend_units.include?(frontend)
  upstreams = config["upstreams"]
  unless upstreams.is_a?(Hash) && !upstreams.empty?
    err("#{path}: upstreams は空でない object")
    upstreams = {}
  end
  upstreams.each do |name, url|
    err("#{path}: upstream #{name} が存在しない frontend unit を指している") unless frontend_units.include?(name.to_s)
    err("#{path}: upstream #{name} の URL が不正: #{url}") unless url.is_a?(String) && url.match?(%r{\Ahttps?://[A-Za-z0-9._-]+:\d+\z})
  end
  routes = config["routes"]
  unless routes.is_a?(Array) && !routes.empty?
    err("#{path}: routes は空でない array")
    routes = []
  end
  routes.each do |route|
    unless route.is_a?(Hash) && route["path"].is_a?(String) && route["path"].start_with?("/") && route["upstream"].is_a?(String)
      err("#{path}: route は path と upstream を持つ object")
      next
    end
    err("#{path}: route #{route["path"]} の upstream がない: #{route["upstream"]}") unless upstreams.key?(route["upstream"])
  end
  err("#{path}: frontend #{frontend} の upstream がない") unless upstreams.key?(frontend)
  err("#{path}: frontend #{frontend} への route がない") unless routes.any? { |route| route.is_a?(Hash) && route["upstream"] == frontend }
  site = config["site"]
  unless site.is_a?(Hash)
    err("#{path}: site は object")
    next
  end
  %w[name logo icon].each do |key|
    value = site[key]
    err("#{path}: site.#{key} が空") unless value.is_a?(String) && !value.empty?
    err("#{path}: site.#{key} に placeholder がある") if value.to_s.match?(/CHANGE-ME|example\.invalid/i)
  end
end

gateway = "base/sukhi-gateway.container"
gateway_lines = lines(gateway)
err("#{gateway}: instance.json の read-only mount がない") unless gateway_lines.include?("Volume=/etc/sukhi/instance.json:/etc/sukhi/instance.json:ro")
err("#{gateway}: SUKHI_INSTANCE_CONFIG がない") unless gateway_lines.include?("Environment=SUKHI_INSTANCE_CONFIG=/etc/sukhi/instance.json")
gateway_lines.grep(/\AVolume=/).each do |line|
  source, target, mode = line.delete_prefix("Volume=").split(":", 3)
  next unless source&.start_with?("/")
  err("#{gateway}: rootless で使えない相対 bind mount") unless target&.start_with?("/")
  err("#{gateway}: instance config は read-only で mount する") if target == "/etc/sukhi/instance.json" && mode != "ro"
end

# 2. 環境ごとの sukhi.version
Dir.glob("overlays/*").select { |d| File.directory?(d) }.sort.each do |d|
  env = File.basename(d)
  path = File.join(d, "sukhi.version")
  unless File.file?(path)
    err("#{path} がない")
    next
  end
  m = lines(path).each_with_object({}) do |l, h|
    k = l.sub(/#.*/, "").match(/\A\s*([A-Za-z0-9._-]+)\s*:\s*(.*?)\s*\z/)
    h[k[1]] = k[2] if k
  end
  err("#{path}: requires-sync(整数)がない") unless m["requires-sync"].to_s.match?(/\A\d+\z/)
  ver = m["version"].to_s
  if env == "prod"
    err("#{path}: prod の version はリリースの semver(例 1.0.0): '#{ver}'") unless ver.match?(/\A\d+\.\d+\.\d+\z/)
  else
    err("#{path}: version は semver か sha-<commit>: '#{ver}'") unless ver.match?(/\A(\d+\.\d+\.\d+|sha-[0-9a-f]{7,40})\z/)
  end
  names.each do |n|
    dg = m["digest.#{n}"].to_s
    if !dg.match?(/\Asha256:[0-9a-f]{64}\z/)
      err("#{path}: digest.#{n} が sha256:<64桁> でない: '#{dg}'")
    elsif dg == ZERO
      placeholder("#{path}: digest.#{n} が仮(0 埋め)", strict)
    end
  end
  # base が使わない digest は置かない(古い行が残るのを防ぐ)
  (m.keys.grep(/\Adigest\./) - names.map { |n| "digest.#{n}" }).each do |k|
    err("#{path}: #{k} は base のどの unit も使っていない")
  end
end

# 3. 秘密を値で書いていないか(Secret= か podman secret で渡す)
(Dir.glob("base/*") + Dir.glob("overlays/**/*")).select { |f| File.file?(f) }.each do |f|
  lines(f).each_with_index do |l, i|
    err("#{f}:#{i + 1}: 秘密らしい値が Environment= にある。podman secret を使う") if l.match?(SECRET_ENV)
  end
end

# 4. overlay は存在する unit にだけ当てる
Dir.glob("overlays/*/*.d").select { |d| File.directory?(d) }.sort.each do |d|
  unit = File.basename(d, ".d")
  err("#{d}: base/#{unit} が無い") unless File.file?("base/#{unit}")
end

# 5. 埋めたあとの確認(sukhi-setup の bin/sukhi-render が要る)
setup = ENV["SUKHI_SETUP"].to_s
cosign = ENV["SUKHI_COSIGN"] == "1"
if !setup.empty?
  renderer = File.join(setup, "bin", "sukhi-render")
  if File.file?(renderer)
    load renderer
    Dir.mktmpdir do |tmp|
      Dir.glob("overlays/*").select { |d| File.directory?(d) }.sort.each do |d|
        env = File.basename(d)
        out = File.join(tmp, env)
        FileUtils.mkdir_p(out)
        FileUtils.cp_r("base/.", out)
        FileUtils.cp_r("#{d}/.", out)
        File.delete(File.join(out, "sukhi.version")) if File.exist?(File.join(out, "sukhi.version"))
        begin
          Sukhi::Render.render_dir(File.join(d, "sukhi.version"), out)
        rescue Sukhi::Render::Error => e
          err("#{env}: sukhi-render が失敗: #{e.message}")
          next
        end
        files = Dir.glob("#{out}/**/*").select { |f| File.file?(f) }
        files.each { |f| err("#{env}: 埋まっていない {{ }} が残っている: #{f}") if File.read(f).include?("{{") }
        next unless cosign

        files.flat_map { |f| lines(f).grep(/\AImage=/).map { |l| l.delete_prefix("Image=") } }.uniq.sort.each do |img|
          next unless img.start_with?("ghcr.io/sukhi-social/") && !img.end_with?("@#{ZERO}")

          ref = "#{img.split('@').first.sub(/:[^:\/]+\z/, '')}@#{img.split('@').last}"
          _, st = Open3.capture2e("cosign", "verify", "--certificate-oidc-issuer", "https://token.actions.githubusercontent.com",
                                  "--certificate-identity-regexp", SIGNER_RE, ref)
          err("#{env}: 署名を確認できない: #{ref}") unless st.success?
        end
      end
    end
  else
    err("#{renderer} がない")
  end
elsif cosign
  err("SUKHI_COSIGN=1 には SUKHI_SETUP(sukhi-setup のチェックアウト)が要る")
end

if @failed
  exit 1
else
  puts "ok"
end
