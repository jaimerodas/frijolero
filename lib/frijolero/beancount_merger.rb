# frozen_string_literal: true

require 'set'

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
      total_entries = @files.sum { |file| process_one(file, existing_includes) }
      report_totals(total_entries)
    end

    private

    def process_one(file, existing_includes)
      entries = count_entries(file)
      basename = File.basename(file)
      relative_path = "#{extract_prefix(file)}/#{basename}"

      if existing_includes.include?(relative_path)
        puts "Skipped (already included): #{basename}" unless @quiet
      elsif @dry_run
        puts "Would add include: #{relative_path} (#{entries} entries)" unless @quiet
      else
        File.open(@output, 'a') { |out| out.puts "include \"#{relative_path}\"" }
        puts "Merged: #{basename} (#{entries} entries)" unless @quiet
      end

      entries
    end

    def report_totals(total_entries)
      return if @quiet

      puts
      if @dry_run
        puts "Dry run complete. Would merge #{total_entries} entries from #{@files.size} file(s)."
      else
        puts "Done. Merged #{total_entries} entries from #{@files.size} file(s) into #{@output}"
      end
    end

    def validate!
      raise ArgumentError, 'No input files provided' if @files.empty?
      unless @output
        raise ArgumentError,
              'Output file not specified. Set paths.beancount_main in ~/.frijolero/config.yaml or use -o'
      end

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
        File.basename(file, '.*')
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
  end
end
