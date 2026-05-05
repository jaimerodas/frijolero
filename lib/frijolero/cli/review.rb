# frozen_string_literal: true

require 'optparse'

module Frijolero
  class CLI
    class Review
      include Helpers

      DEFAULT_PORT = 4567

      def self.call(args)
        new(args).call
      end

      def initialize(args)
        @args = args
        @options = { port: DEFAULT_PORT }
      end

      def call
        parser = parse_options
        require_input!(@args.first, parser)

        input = @args.first
        ensure_input_exists!(input)
        check_config!

        account = @options[:account] ||
                  AccountConfig.beancount_account_for_file(input) ||
                  report_account_lookup_failure(input, 'account', '-a')

        boot_review_server(input, account)
      end

      private

      def parse_options
        parser = OptionParser.new do |opts|
          opts.banner = 'Usage: frijolero review FILE.json [-p PORT]'

          opts.on('-p', '--port PORT', Integer, 'Server port (default: 4567)') do |v|
            @options[:port] = v
          end

          opts.on('-a', '--account ACCOUNT', 'Primary account (auto-detected from filename if omitted)') do |v|
            @options[:account] = v
          end

          help_option(opts)
        end
        parser.parse!(@args)
        parser
      end

      def ensure_input_exists!(input)
        return if File.exist?(input)

        warn "Error: File not found: #{input}"
        exit 1
      end

      def boot_review_server(input, account)
        require_relative '../web/app'

        Web::App.set :json_file, File.expand_path(input)
        Web::App.set :beancount_account, account
        Web::App.set :accounts_list, accounts_for_autocomplete

        announce_server(input, account)
        open_browser_async
        Web::App.run!(port: @options[:port], bind: 'localhost')
      end

      def announce_server(input, account)
        url = "http://localhost:#{@options[:port]}"
        UI.puts "{{*}} Starting review server at {{bold:#{url}}}"
        UI.puts "{{i}} Reviewing: #{File.basename(input)} (#{account})"
        UI.puts 'Press Ctrl+C to stop'
      end

      def open_browser_async
        url = "http://localhost:#{@options[:port]}"
        Thread.new do
          sleep 0.5
          system('open', url)
        end
      end
    end
  end
end
