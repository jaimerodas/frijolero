# frozen_string_literal: true

require 'optparse'

module Frijolero
  class CLI
    class Migrate
      include Helpers

      MISSING_OLD_ROOT_MESSAGE =
        'Old output directory not specified. Pass --old-output-dir PATH ' \
        'or restore paths.statements_output in config.yaml'

      def self.call(args)
        new(args).call
      end

      def initialize(args)
        @args = args
        @options = { apply: false, prompt: true, old_output_dir: nil }
      end

      def call
        parse_options
        check_config!

        old_root = resolve_old_root
        new_root = Config.statements_output_dir
        main_file = Config.beancount_main_file

        LayoutMigrator.new(
          old_root: old_root,
          new_root: new_root,
          main_file: main_file,
          apply: @options[:apply],
          prompt: @options[:prompt]
        ).run
      rescue ArgumentError, RuntimeError => e
        warn "Error: #{e.message}"
        exit 1
      end

      private

      def parse_options
        parser = OptionParser.new do |opts|
          opts.banner = 'Usage: frijolero migrate [--apply] [--no-prompt] [--old-output-dir PATH]'

          opts.on('--apply', 'Perform copies, verify, rewrite ledger, then prompt to delete originals') do
            @options[:apply] = true
          end

          opts.on('--no-prompt', 'Skip the final delete prompt; keep originals') do
            @options[:prompt] = false
          end

          opts.on('--old-output-dir PATH',
                  'Old statements_output directory (defaults to paths.statements_output in config)') do |v|
            @options[:old_output_dir] = v
          end

          help_option(opts)
        end
        parser.parse!(@args)
      end

      def resolve_old_root
        path = @options[:old_output_dir] || Config.data.dig('paths', 'statements_output')
        raise ArgumentError, MISSING_OLD_ROOT_MESSAGE unless path

        File.expand_path(path)
      end
    end
  end
end
