# frozen_string_literal: true

require "optparse"
require "fileutils"

module Frijolero
  class CLI
    TEMPLATES_DIR = File.expand_path("templates", __dir__)

    def self.run(args = ARGV)
      new.run(args)
    end

    def run(args)
      Frijolero::UI.setup

      if args.empty? || args.first == "--help" || args.first == "-h"
        show_help
        return
      end

      if args.first == "--version" || args.first == "-v"
        puts "frijolero #{VERSION}"
        return
      end

      command = args.shift
      case command
      when "init"
        run_init(args)
      when "process"
        run_process(args)
      when "detail"
        run_detail(args)
      when "convert"
        run_convert(args)
      when "merge"
        run_merge(args)
      when "csv"
        run_csv(args)
      else
        warn "Unknown command: #{command}"
        warn "Run 'frijolero --help' for usage information"
        exit 1
      end
    end

    private

    def show_help
      puts <<~HELP
        Usage: frijolero COMMAND [OPTIONS]

        Commands:
          init               Create ~/.frijolero/ with example configs
          process            Process PDF statements end-to-end
          detail FILE.json   Enrich transactions with config rules
          convert FILE.json  Convert JSON to Beancount format
          merge FILE.bc      Merge beancount into main ledger
          csv FILE.json      Convert JSON to CSV

        Options:
          --help, -h         Show this help message
          --version, -v      Show version

        Run 'frijolero COMMAND --help' for command-specific options.
      HELP
    end

    def run_init(args)
      if args.include?("--help") || args.include?("-h")
        puts <<~HELP
          Usage: frijolero init

          Creates ~/.frijolero/ directory with example configuration files:
            - config.yaml      API keys and paths
            - accounts.yaml    Account name → beancount account mapping
            - detailers/       Directory for transaction matching rules
        HELP
        return
      end

      config_dir = Config.config_dir

      if Config.initialized?
        warn "Configuration already exists at #{config_dir}"
        warn "Remove it first if you want to reinitialize"
        exit 1
      end

      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(Config.detailers_dir)

      FileUtils.cp(File.join(TEMPLATES_DIR, "config.yaml"), Config.config_file)
      FileUtils.cp(File.join(TEMPLATES_DIR, "accounts.yaml"), Config.accounts_file)
      FileUtils.cp(File.join(TEMPLATES_DIR, "detailer.yaml"), File.join(Config.detailers_dir, "example.yaml"))

      puts "Created configuration at #{config_dir}"
      puts
      puts "Edit these files to configure frijolero:"
      puts "  #{Config.config_file}         - API keys and paths"
      puts "  #{Config.accounts_file}       - Account mappings"
      puts "  #{Config.detailers_dir}/   - Transaction matching rules"
    end

    def run_process(args)
      options = {dry_run: false, interactive: true}

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: frijolero process [OPTIONS]"

        opts.on("--dry-run", "Show what would be processed without making changes") do
          options[:dry_run] = true
        end

        opts.on("--auto-accept-prompts", "Skip interactive prompts (auto-yes)") do
          options[:interactive] = false
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit
        end
      end

      parser.parse!(args)

      check_config!
      StatementProcessor.new(
        dry_run: options[:dry_run],
        interactive: options[:interactive]
      ).run
    end

    def run_detail(args)
      options = {}

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: frijolero detail FILE.json [-c CONFIG.yaml]"

        opts.on("-c", "--config CONFIG", "Config YAML file (auto-detected from filename if omitted)") do |v|
          options[:config] = v
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit
        end
      end

      parser.parse!(args)
      file = args.first

      unless file
        warn "Error: Input file required"
        warn parser
        exit 1
      end

      config = options[:config]
      auto_detected = false

      unless config
        config = AccountConfig.detailer_config_for_file(file)
        if config
          auto_detected = true
        else
          UI.puts "{{x}} Could not auto-detect config for '#{File.basename(file)}'"
          UI.puts "Available accounts: #{AccountConfig.available_accounts.join(", ")}"
          UI.puts "Use -c to specify a config file explicitly"
          exit 1
        end
      end

      filename = File.basename(file)

      UI.frame("Detailing: #{filename}") do
        UI.puts "Config: #{UI.short_path(config)}" if auto_detected

        transactions = JSON.load_file(file).dig("transactions") || []
        UI.puts "Found #{transactions.size} transactions#{UI.transaction_summary(transactions)}"

        stats = Detailer.new(file, config).run
        UI.detailer_stats(stats)
      end
    end

    def run_convert(args)
      options = {}

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: frijolero convert FILE.json [-a ACCOUNT] [-o OUTPUT.beancount]"

        opts.on("-a", "--account ACCOUNT", "Primary account (auto-detected from filename if omitted)") do |v|
          options[:account] = v
        end

        opts.on("-o", "--output FILE", "Output Beancount file") do |v|
          options[:output] = v
        end

        opts.on("-e", "--expense ACCOUNT", "Default expense account (default: Expenses:FIXME)") do |v|
          options[:expense_account] = v
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit
        end
      end

      parser.parse!(args)
      input = args.first

      unless input
        warn "Error: Input file required"
        warn parser
        exit 1
      end

      options[:input] = input

      unless options[:account]
        account = AccountConfig.beancount_account_for_file(input)
        if account
          puts "Auto-detected account: #{account}"
          options[:account] = account
        else
          warn "Error: Could not auto-detect account for '#{File.basename(input)}'"
          warn "Available accounts: #{AccountConfig.available_accounts.join(", ")}"
          warn "Use -a to specify an account explicitly"
          exit 1
        end
      end

      BeancountConverter.convert(**options)
    end

    def run_merge(args)
      options = {dry_run: false}

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: frijolero merge FILE [FILE...] [-o MAIN_FILE] [--dry-run]"

        opts.on("-o", "--output FILE", "Main beancount file to append to") do |v|
          options[:output] = v
        end

        opts.on("--dry-run", "Show what would be merged without making changes") do
          options[:dry_run] = true
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit
        end
      end

      parser.parse!(args)

      if args.empty?
        warn "Error: No input files provided"
        warn parser
        exit 1
      end

      begin
        BeancountMerger.new(
          files: args,
          output: options[:output],
          dry_run: options[:dry_run]
        ).run
      rescue ArgumentError => e
        warn "Error: #{e.message}"
        exit 1
      end
    end

    def run_csv(args)
      options = {}

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: frijolero csv FILE.json [-o OUTPUT.csv]"

        opts.on("-o", "--output FILE", "Output CSV file") do |v|
          options[:output] = v
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit
        end
      end

      parser.parse!(args)
      input = args.first

      unless input
        warn "Error: Input file required"
        warn parser
        exit 1
      end

      CsvConverter.convert(input: input, output: options[:output])
    end

    def check_config!
      return if Config.initialized?

      warn "Configuration not found. Run 'frijolero init' first."
      exit 1
    end
  end
end
