# frozen_string_literal: true

require 'open3'
require 'tempfile'
require 'json'

module Tippecanoe
  class Error < StandardError; end

  class NotInstalledError < Error; end

  class ExecutionError < Error
    attr_reader :status, :stdout, :stderr

    def initialize(msg, status:, stdout:, stderr:)
      super(msg)
      @status = status
      @stdout = stdout
      @stderr = stderr
    end
  end

  # Main wrapper class
  class Builder
    attr_reader :options, :binary

    # options - Hash of tippecanoe options (snake_case or strings allowed)
    # binary - optional path to tippecanoe binary, default 'tippecanoe'
    def initialize(options = {}, binary: 'tippecanoe')
      @options = normalize_keys(options)
      @binary = binary
    end

    # Runs tippecanoe with the provided input and options.
    #
    # input: path string, Array of paths, or an IO-like object (responds to :read / :each)
    # output: path to output mbtiles (if not provided, delegated to tippecanoe which defaults to ./out.mbtiles)
    #
    # Returns: { stdout: "...", stderr: "...", status: Process::Status }
    #
    # Raises NotInstalledError when tippecanoe is not available, ExecutionError on non-zero exit.
    def build(input:, output: nil, pmtiles: nil, extra_args: [])
      ensure_installed!

      File.delete(output) if output && File.file?(output)

      if pmtiles
        # default mbtiles name
        tmp_out = output || Tempfile.new(['tippecanoe', '.mbtiles']).path
        res = build_mbtiles(input: input, output: tmp_out, extra_args: extra_args)

        pmtiles_path = pmtiles.is_a?(String) ? pmtiles : tmp_out.sub(/\.mbtiles$/, '.pmtiles')
        run_pmtiles_convert(tmp_out, pmtiles_path)

        res.merge(pmtiles: pmtiles_path)
      else
        build_mbtiles(input: input, output: output, extra_args: extra_args)
      end
    end

    def pmtiles_merge(output: './merged.pmtiles', input: './*.pmtiles')
      ensure_installed!

      raise IOError, "#{output} already exists." if File.exist?(output)

      cmd = "tile-join -o #{output} #{input}"
      run_command(cmd)
    end

    # Check tippecanoe availability
    def installed?
      system("#{binary} --version > /dev/null 2>&1")
    end

    def ensure_installed!
      raise NotInstalledError, "tippecanoe binary not found at '#{binary}'" unless installed?
    end

    # Get version string from tippecanoe
    def version
      out, err, status = Open3.capture3(binary, '--version')
      return out.strip if status.success?

      raise NotInstalledError, "couldn't get version: #{err.strip}"
    end

    def build_mbtiles(input:, output:, extra_args:)
      args = [binary]
      args.concat(options_to_flags(options))
      args.concat(extra_args.map(&:to_s))
      args.concat(output ? ['-o', output.to_s] : [])

      stdin_io = nil
      if input.is_a?(String) || input.is_a?(Pathname)
        args << input.to_s
      elsif input.is_a?(Array)
        args.concat(input.map(&:to_s))
      elsif input.respond_to?(:read) || input.respond_to?(:each)
        args << '-'
        stdin_io = input
      else
        raise ArgumentError, "unsupported input type: #{input.class}"
      end

      run_command(args, stdin_io)
    end

    def run_pmtiles_convert(mbtiles, pmtiles)
      raise NotInstalledError, 'pmtiles CLI not found in PATH' unless system('pmtiles version > /dev/null 2>&1')

      out, err, status = Open3.capture3('pmtiles', 'convert', mbtiles.to_s, pmtiles.to_s)
      puts out
      unless status.success?
        raise ExecutionError.new(
          'pmtiles convert failed',
          status: status,
          stdout: out,
          stderr: err,
        )
      end

      pmtiles
    end

    # Convert ruby options hash into an array of CLI flags.
    # Example: { generate_ids: true, maxzoom: 12 } -> ['--generate-ids', '--maximum-zoom', '12']
    # This provides a mapping for commonly used option names, but passes unknown names as `--name value`.
    def options_to_flags(hash)
      flags = []
      hash.each do |k, v|
        key = k.to_s
        flag = map_key_to_flag(key)

        if v == true
          flags << flag
        elsif v == false || v.nil?
          # skip explicit false/nil
        elsif v.is_a?(Array)
          v.each { |elem| flags << flag << elem.to_s }
        else
          flags << flag << v.to_s
        end
      end
      flags
    end

    # Common key mapping (snake_case or camelCase -> tippecanoe long options)
    def map_key_to_flag(key)
      mapping = {
        # Common aliases
        'generate_ids' => '--generate-ids',
        'no_generate_ids' => '--no-generate-ids',
        'drop_rate' => '--drop-rate',
        'drop_rate_k' => '--drop-rate-k',
        'no_outline' => '--no-outline',
        'no_feature_limit' => '--no-feature-limit',
        'coalesce' => '--coalesce',
        'force' => '--force',
        'read_metadata' => '--read-parallel',
        'read_parallel' => '--read-parallel',
        'simplify_only_low_zoom' => '--simplify-only-low-zoom',
        'full_detail' => '--full-detail',
        'minimum_detail' => '--minimum-detail',
        'maximum_detail' => '--maximum-detail',
        'minimum_zoom' => '--minimum-zoom',
        'maximum_zoom' => '--maximum-zoom',
        'minimum_tile_size' => '--minimum-tile-size',
        'maximum_tile_size' => '--maximum-tile-size',
        'keep_input_features' => '--keep-input-features',
        'no_stats' => '--no-stats',
        'no_tiling' => '--no-tile-clipping',
        'tile_size' => '--tile-size',
        'layer' => '--layer',
        'preserve_input_order' => '--preserve-input-order',
        'progress' => '--progress',
        # generic fallback handled below
      }

      mapping[key] || "--#{key.tr("_", "-")}"
    end

    def normalize_keys(h)
      new_h = {}
      h.each { |k, v| new_h[k.to_s] = v }
      new_h
    end

    def run_command(args, stdin_io = nil)
      stdout_buf = +''
      stderr_buf = +''
      status = nil

      # Use Open3.popen3 to allow streaming large GeoJSON via stdin.
      Open3.popen3(*args) do |stdin, stdout, stderr, wait_thr|
        # Thread to forward stdout
        out_thread = Thread.new do
          stdout_buf << stdout.readpartial(16_384) until stdout.eof?
        rescue EOFError
          # noop
        end

        # Thread to forward stderr
        err_thread = Thread.new do
          stderr_buf << stderr.readpartial(16_384) until stderr.eof?
        rescue EOFError
          # noop
        end

        # Write to stdin if provided
        if stdin_io
          begin
            if stdin_io.respond_to?(:each)
              stdin_io.each { |chunk| stdin.write(chunk) }
            else
              stdin.write(stdin_io.read)
            end
          ensure
            stdin.close
          end
        else
          stdin.close
        end

        # wait for threads and process
        out_thread.join
        err_thread.join
        status = wait_thr.value
      end

      if status && status.exitstatus != 0
        raise ExecutionError.new(
          "tippecanoe failed (exit #{status.exitstatus})",
          status: status,
          stdout: stdout_buf.dup,
          stderr: stderr_buf.dup,
        )
      end

      { stdout: stdout_buf.dup, stderr: stderr_buf.dup, status: status }
    end
  end
end
