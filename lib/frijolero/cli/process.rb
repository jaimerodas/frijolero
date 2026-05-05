# frozen_string_literal: true

require 'optparse'

module Frijolero
  class CLI
    class Process
      include Helpers

      def self.call(args)
        new(args).call
      end

      def initialize(args)
        @args = args
        @options = { dry_run: false, interactive: true }
      end

      def call
        parse_options
        check_config!

        StatementProcessor.new(
          dry_run: @options[:dry_run],
          interactive: @options[:interactive]
        ).run
      end

      private

      def parse_options
        OptionParser.new do |opts|
          opts.banner = 'Usage: frijolero process [OPTIONS]'

          opts.on('--dry-run', 'Show what would be processed without making changes') do
            @options[:dry_run] = true
          end

          opts.on('--auto-accept-prompts', 'Skip interactive prompts (auto-yes)') do
            @options[:interactive] = false
          end

          help_option(opts)
        end.parse!(@args)
      end
    end
  end
end
