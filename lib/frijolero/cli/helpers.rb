# frozen_string_literal: true

module Frijolero
  class CLI
    module Helpers
      private

      def check_config!
        return if Config.initialized?

        warn "Configuration not found. Run 'frijolero init' first."
        exit 1
      end

      def help_option(opts)
        opts.on('-h', '--help', 'Show this help') do
          puts opts
          exit
        end
      end

      def require_input!(file, parser)
        return if file

        warn 'Error: Input file required'
        warn parser
        exit 1
      end

      def accounts_for_autocomplete
        Accounts.new.all
      rescue ArgumentError
        []
      end

      def report_account_lookup_failure(file, label, flag)
        UI.puts "{{x}} Could not auto-detect #{label} for '#{File.basename(file)}'"
        UI.puts "Available accounts: #{AccountConfig.available_accounts.join(', ')}"
        UI.puts "Use #{flag} to specify a #{label} explicitly"
        exit 1
      end
    end
  end
end
