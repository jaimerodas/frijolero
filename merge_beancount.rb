#!/usr/bin/env ruby
# frozen_string_literal: true

require 'dotenv/load'
require 'optparse'

class BeancountMerger
  def initialize(files:, output:, dry_run: false)
    @files = files
    @output = output
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
    raise ArgumentError, "Output file not specified. Use -o or set BEANCOUNT_MAIN_FILE" unless @output

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

if $PROGRAM_NAME == __FILE__
  options = {
    output: ENV["BEANCOUNT_MAIN_FILE"],
    dry_run: false
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby merge_beancount.rb FILE [FILE...] [-o MAIN_FILE] [--dry-run]"

    opts.on("-o", "--output FILE", "Main beancount file to append to (default: BEANCOUNT_MAIN_FILE env)") do |v|
      options[:output] = v
    end

    opts.on("--dry-run", "Show what would be merged without making changes") do
      options[:dry_run] = true
    end

    opts.on("-h", "--help", "Show this help message") do
      puts opts
      exit 0
    end
  end

  parser.parse!

  if ARGV.empty?
    warn "Error: No input files provided"
    warn parser
    exit 1
  end

  begin
    BeancountMerger.new(
      files: ARGV,
      output: options[:output],
      dry_run: options[:dry_run]
    ).run
  rescue ArgumentError => e
    warn "Error: #{e.message}"
    exit 1
  end
end
