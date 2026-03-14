# frozen_string_literal: true

require "set"
require "fileutils"

module Frijolero
  class BeancountMerger
    def initialize(files:, output: nil, dry_run: false, quiet: false)
      @files = files
      @output = output || Config.beancount_main_file
      @dry_run = dry_run
      @quiet = quiet
    end

    def run
      validate!

      existing_includes = read_existing_includes
      total_entries = 0

      @files.each do |file|
        entries = count_entries(file)
        total_entries += entries
        basename = File.basename(file)

        prefix = extract_prefix(file)
        relative_path = "transactions/#{prefix}/#{basename}"

        if existing_includes.include?(relative_path)
          puts "Skipped (already included): #{basename}" unless @quiet
          next
        end

        if @dry_run
          puts "Would copy: #{basename} → #{relative_path}" unless @quiet
          puts "Would add include: #{relative_path} (#{entries} entries)" unless @quiet
        else
          include_file(file, prefix)
          puts "Merged: #{basename} (#{entries} entries)" unless @quiet
        end
      end

      unless @quiet
        puts
        if @dry_run
          puts "Dry run complete. Would merge #{total_entries} entries from #{@files.size} file(s)."
        else
          puts "Done. Merged #{total_entries} entries from #{@files.size} file(s) into #{@output}"
        end
      end
    end

    private

    def validate!
      raise ArgumentError, "No input files provided" if @files.empty?
      raise ArgumentError, "Output file not specified. Set paths.beancount_main in ~/.frijolero/config.yaml or use -o" unless @output

      @files.each do |file|
        raise ArgumentError, "File not found: #{file}" unless File.exist?(file)
      end
    end

    def count_entries(file)
      File.readlines(file).count { |line| line.match?(/^\d{4}-\d{2}-\d{2}\s+\*/) }
    end

    def extract_prefix(file)
      parsed = AccountConfig.parse_filename(file)
      if parsed
        parsed[0]
      else
        File.basename(file, ".*")
      end
    end

    def read_existing_includes
      return Set.new unless @output && File.exist?(@output)

      includes = Set.new
      File.readlines(@output).each do |line|
        if (match = line.match(/^include\s+"(.+)"\s*$/))
          includes.add(match[1])
        end
      end
      includes
    end

    def include_file(file, prefix)
      output_dir = File.dirname(@output)
      target_dir = File.join(output_dir, "transactions", prefix)
      target_path = File.join(target_dir, File.basename(file))
      relative_path = "transactions/#{prefix}/#{File.basename(file)}"

      FileUtils.mkdir_p(target_dir)
      FileUtils.cp(file, target_path)

      File.open(@output, "a") do |out|
        out.puts "include \"#{relative_path}\""
      end
    end
  end
end
