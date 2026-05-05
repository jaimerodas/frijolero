# frozen_string_literal: true

require 'optparse'

module Frijolero
  class CLI
    class Merge
      include Helpers

      def self.call(args)
        new(args).call
      end

      def initialize(args)
        @args = args
        @options = { dry_run: false }
      end

      def call
        parser = parse_options

        if @args.empty?
          warn 'Error: No input files provided'
          warn parser
          exit 1
        end

        BeancountMerger.new(
          files: @args,
          output: @options[:output],
          dry_run: @options[:dry_run]
        ).run
      rescue ArgumentError => e
        warn "Error: #{e.message}"
        exit 1
      end

      private

      def parse_options
        parser = OptionParser.new do |opts|
          opts.banner = 'Usage: frijolero merge FILE [FILE...] [-o MAIN_FILE] [--dry-run]'

          opts.on('-o', '--output FILE', 'Main beancount file to append to') do |v|
            @options[:output] = v
          end

          opts.on('--dry-run', 'Show what would be merged without making changes') do
            @options[:dry_run] = true
          end

          help_option(opts)
        end
        parser.parse!(@args)
        parser
      end
    end
  end
end
