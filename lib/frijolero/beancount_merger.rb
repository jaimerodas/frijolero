# frozen_string_literal: true

module Frijolero
  class BeancountMerger
    def initialize(files:, output: nil, dry_run: false)
      @files = files
      @output = output || Config.beancount_main_file
      @dry_run = dry_run
    end

    def run
      validate!

      total_entries = 0

      @files.each do |file|
        entries = count_entries(file)
        total_entries += entries

        if @dry_run
          puts "Would merge: #{File.basename(file)} (#{entries} entries)"
        else
          append_file(file)
          puts "Merged: #{File.basename(file)} (#{entries} entries)"
        end
      end

      puts
      if @dry_run
        puts "Dry run complete. Would merge #{total_entries} entries from #{@files.size} file(s)."
      else
        puts "Done. Merged #{total_entries} entries from #{@files.size} file(s) into #{@output}"
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

    def append_file(file)
      content = File.read(file).rstrip
      basename = File.basename(file)
      header = "; === Start: #{basename} ==="
      footer = "; === End: #{basename} ==="

      File.open(@output, "a") do |out|
        out.puts
        out.puts header
        out.puts
        out.puts content
        out.puts
        out.puts footer
      end
    end
  end
end
