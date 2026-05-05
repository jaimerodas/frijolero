# frozen_string_literal: true

require 'fileutils'

module Frijolero
  class CLI
    class Init
      include Helpers

      TEMPLATES_DIR = File.expand_path('../templates', __dir__)

      def self.call(args)
        new(args).call
      end

      def initialize(args)
        @args = args
      end

      def call
        return show_help if help_requested?

        abort_if_initialized

        FileUtils.mkdir_p(Config.config_dir)
        FileUtils.mkdir_p(Config.detailers_dir)
        copy_templates
        announce
      end

      private

      def help_requested?
        @args.include?('--help') || @args.include?('-h')
      end

      def show_help
        puts <<~HELP
          Usage: frijolero init

          Creates ~/.frijolero/ directory with example configuration files:
            - config.yaml      API keys and paths
            - accounts.yaml    Account name → beancount account mapping
            - detailers/       Directory for transaction matching rules
        HELP
      end

      def abort_if_initialized
        return unless Config.initialized?

        warn "Configuration already exists at #{Config.config_dir}"
        warn 'Remove it first if you want to reinitialize'
        exit 1
      end

      def copy_templates
        FileUtils.cp(File.join(TEMPLATES_DIR, 'config.yaml'), Config.config_file)
        FileUtils.cp(File.join(TEMPLATES_DIR, 'accounts.yaml'), Config.accounts_file)
        FileUtils.cp(File.join(TEMPLATES_DIR, 'detailer.yaml'), File.join(Config.detailers_dir, 'example.yaml'))
      end

      def announce
        puts "Created configuration at #{Config.config_dir}"
        puts
        puts 'Edit these files to configure frijolero:'
        puts "  #{Config.config_file}         - API keys and paths"
        puts "  #{Config.accounts_file}       - Account mappings"
        puts "  #{Config.detailers_dir}/   - Transaction matching rules"
      end
    end
  end
end
