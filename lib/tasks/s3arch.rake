# frozen_string_literal: true

require_relative '../s3arch/version'

module S3archLayerBuilder
  module_function

  def build_layer(ruby_version:, architecture:, output_file:, s3arch_version:)
    require 'tmpdir'
    require 'fileutils'

    FileUtils.mkdir_p(File.dirname(output_file))

    puts "🔨 Building Lambda layer (Ruby #{ruby_version} / #{architecture}, s3arch #{s3arch_version})..."

    tmpdir = Dir.mktmpdir('s3arch-layer')
    begin
      write_gemfile(tmpdir, s3arch_version)
      run_docker_build(tmpdir, ruby_version, architecture)
      strip_layer("#{tmpdir}/layer")
      verify_layer("#{tmpdir}/layer")
      create_zip("#{tmpdir}/layer", output_file)
    ensure
      system('sudo', 'rm', '-rf', tmpdir) || FileUtils.rm_rf(tmpdir)
    end
  end

  def write_gemfile(tmpdir, s3arch_version)
    File.write("#{tmpdir}/Gemfile", <<~GEMFILE)
      source 'https://rubygems.org'
      gem 's3arch', '#{s3arch_version}'
    GEMFILE
  end

  def run_docker_build(tmpdir, ruby_version, architecture)
    docker_image = "public.ecr.aws/sam/build-ruby#{ruby_version}:latest-#{architecture}"
    platform = architecture == 'x86_64' ? 'linux/amd64' : 'linux/arm64'

    build_script = docker_build_script(ruby_version)

    docker_cmd = [
      'docker', 'run', '--rm',
      '--platform', platform,
      '-v', "#{tmpdir}:/build",
      '-w', '/build',
      docker_image,
      '/bin/bash', '-c', build_script
    ]

    puts "🐳 Building in Docker (#{docker_image})..."
    abort '❌ Docker build failed' unless system(*docker_cmd)
  end

  def docker_build_script(ruby_version)
    <<~BASH
      yum install -y sqlite-devel 2>/dev/null || dnf install -y sqlite-devel 2>/dev/null
      bundle config set --local path /build/layer/ruby/gems/#{ruby_version}.0
      bundle config set --local without "development test"
      bundle config set --local deployment false
      bundle install
      NESTED="/build/layer/ruby/gems/#{ruby_version}.0/ruby/#{ruby_version}.0"
      if [ -d "$NESTED" ]; then
        mkdir -p /build/layer-final/ruby/gems/#{ruby_version}.0
        cp -a "$NESTED"/* /build/layer-final/ruby/gems/#{ruby_version}.0/
        rm -rf /build/layer
        mv /build/layer-final /build/layer
      fi
    BASH
  end

  def strip_layer(layer_dir)
    puts '🧹 Stripping layer...'

    Dir.glob("#{layer_dir}/ruby/gems/*/gems/*/").each do |gem_dir|
      %w[spec test tests doc docs examples benchmarks].each do |fat_dir|
        FileUtils.rm_rf("#{gem_dir}#{fat_dir}")
      end
    end

    junk_patterns = %w[
      *.md *.rdoc *.txt *.c *.h *.o Makefile *.log
      CHANGELOG* HISTORY* LICENSE* README* .gitignore Rakefile
    ]
    junk_patterns.each do |pattern|
      Dir.glob("#{layer_dir}/**/#{pattern}").each { |f| FileUtils.rm_f(f) }
    end

    Dir.glob("#{layer_dir}/**/*.so").each do |so|
      system('strip', '--strip-debug', so, err: File::NULL)
    end
  end

  def verify_layer(layer_dir)
    sqlite_so = Dir.glob("#{layer_dir}/**/sqlite3_native.so") +
                Dir.glob("#{layer_dir}/**/sqlite3.so")
    abort '❌ sqlite3 native extension NOT found in layer' if sqlite_so.empty?
    puts '✅ sqlite3 native extension included'

    s3arch_lib = Dir.glob("#{layer_dir}/**/gems/s3arch-*/lib/s3arch.rb")
    abort '❌ s3arch gem NOT found in layer' if s3arch_lib.empty?
    puts '✅ s3arch gem included'
  end

  def create_zip(layer_dir, output_file)
    FileUtils.rm_f(output_file)
    abort '❌ Failed to create zip' unless system('zip', '-qr', output_file, 'ruby/', chdir: layer_dir)

    size = `du -h #{output_file}`.split("\t").first
    puts "✅ Layer built: #{output_file} (#{size})"
  end
end

namespace :s3arch do
  namespace :layer do
    desc 'Build the Lambda layer zip (defaults: RUBY_VERSION=3.4, ARCHITECTURE=x86_64)'
    task :build do
      ruby_version   = ENV.fetch('RUBY_VERSION', '3.4')
      architecture   = ENV.fetch('ARCHITECTURE', 'x86_64')
      output_file    = File.expand_path(ENV.fetch('OUTPUT', 'pkg/sqlite-layer.zip'))
      s3arch_version = ENV.fetch('S3ARCH_VERSION', "~> #{S3arch::VERSION.sub(/\.\d+$/, '.0')}")

      S3archLayerBuilder.build_layer(
        ruby_version: ruby_version,
        architecture: architecture,
        output_file: output_file,
        s3arch_version: s3arch_version
      )
    end

    desc 'Build and publish the Lambda layer (set AWS_PROFILE, LAYER_NAME=stowzilla-sqlite3-ruby)'
    task publish: :build do
      layer_name   = ENV.fetch('LAYER_NAME', 'stowzilla-sqlite3-ruby')
      ruby_version = ENV.fetch('RUBY_VERSION', '3.4')
      architecture = ENV.fetch('ARCHITECTURE', 'x86_64')
      output_file  = File.expand_path(ENV.fetch('OUTPUT', 'pkg/sqlite-layer.zip'))

      abort "❌ Layer zip not found at #{output_file}" unless File.exist?(output_file)

      cmd = %w[aws lambda publish-layer-version]
      cmd += ['--layer-name', layer_name]
      cmd += ['--zip-file', "fileb://#{output_file}"]
      cmd += ['--compatible-runtimes', "ruby#{ruby_version}"]
      cmd += ['--compatible-architectures', architecture]

      puts "📤 Publishing layer '#{layer_name}'..."
      puts "   #{cmd.join(' ')}"

      abort '❌ Failed to publish layer' unless system(*cmd)

      puts '✅ Layer published successfully'
    end
  end

  desc 'Rebuild the search index for a given owner: rake s3arch:rebuild[owner-123]'
  task :rebuild, [:owner_id] do |_t, args|
    require 's3arch'

    owner_id = args.owner_id || ENV.fetch('OWNER_ID', nil)
    abort '❌ Usage: rake s3arch:rebuild[OWNER_ID]' unless owner_id

    S3arch.configure(&:from_env!)

    puts "🔄 Rebuilding index for #{owner_id}..."
    S3arch::Indexer.new.rebuild(owner_id)
    puts '✅ Done'
  end

  desc 'Show current s3arch configuration and version info'
  task :info do
    require 's3arch'

    puts "s3arch #{S3arch::VERSION}"
    puts ''
    puts 'Environment:'
    %w[S3ARCH_SOURCE_TABLE S3ARCH_SOURCE_INDEX S3ARCH_INDEX_BUCKET S3ARCH_VERSION_TABLE].each do |var|
      puts "  #{var}=#{ENV.fetch(var, '(not set)')}"
    end
  end
end
