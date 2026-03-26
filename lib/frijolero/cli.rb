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
      when "review"
        run_review(args)
      when "rename"
        run_rename(args)
      when "split"
        run_split(args)
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
          review FILE.json   Review and edit transactions in web UI
          rename             Rename an account across all files
          split [ACCOUNT]    Split inline transactions into monthly files

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
      filename = File.basename(input)

      unless options[:account]
        account = AccountConfig.beancount_account_for_file(input)
        if account
          options[:account] = account
        else
          UI.puts "{{x}} Could not auto-detect account for '#{filename}'"
          UI.puts "Available accounts: #{AccountConfig.available_accounts.join(", ")}"
          UI.puts "Use -a to specify an account explicitly"
          exit 1
        end
      end

      parsed = AccountConfig.parse_filename(input)
      account_config = parsed ? AccountConfig.find_config(parsed.first) : nil
      converter_type = account_config&.dig("converter_type")

      UI.frame("Converting: #{filename}") do
        UI.puts "Account: #{options[:account]}"

        if converter_type == "cetes_directo"
          movements = JSON.load_file(input).dig("movements") || []
          UI.puts "Found #{movements.size} movements"

          output_path = CetesDirectoConverter.convert(
            input: input,
            account: options[:account],
            output: options[:output],
            counterpart_account: account_config["counterpart_account"],
            interest_account: account_config["interest_account"],
            tax_account: account_config["tax_account"],
            gains_account: account_config["gains_account"] || CetesDirectoConverter::DEFAULT_GAINS_ACCOUNT
          )
        else
          transactions = JSON.load_file(input).dig("transactions") || []
          UI.puts "Found #{transactions.size} transactions#{UI.transaction_summary(transactions)}"

          output_path = BeancountConverter.convert(**options)
        end

        UI.puts "Saved: #{UI.short_path(output_path)}"
      end
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

    def run_review(args)
      options = {port: 4567}

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: frijolero review FILE.json [-p PORT]"

        opts.on("-p", "--port PORT", Integer, "Server port (default: 4567)") do |v|
          options[:port] = v
        end

        opts.on("-a", "--account ACCOUNT", "Primary account (auto-detected from filename if omitted)") do |v|
          options[:account] = v
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

      unless File.exist?(input)
        warn "Error: File not found: #{input}"
        exit 1
      end

      check_config!

      account = options[:account]
      unless account
        account = AccountConfig.beancount_account_for_file(input)
        unless account
          UI.puts "{{x}} Could not auto-detect account for '#{File.basename(input)}'"
          UI.puts "Available accounts: #{AccountConfig.available_accounts.join(", ")}"
          UI.puts "Use -a to specify an account explicitly"
          exit 1
        end
      end

      accounts_list = begin
        Accounts.new.all
      rescue ArgumentError
        []
      end

      require_relative "web/app"

      Web::App.set :json_file, File.expand_path(input)
      Web::App.set :beancount_account, account
      Web::App.set :accounts_list, accounts_list

      url = "http://localhost:#{options[:port]}"
      UI.puts "{{*}} Starting review server at {{bold:#{url}}}"
      UI.puts "{{i}} Reviewing: #{File.basename(input)} (#{account})"
      UI.puts "Press Ctrl+C to stop"

      # Open browser after a short delay
      Thread.new do
        sleep 0.5
        system("open", url)
      end

      Web::App.run!(port: options[:port], bind: "localhost")
    end

    def run_rename(args)
      if args.include?("--help") || args.include?("-h")
        puts "Usage: frijolero rename"
        puts
        puts "Interactively rename an account across beancount files,"
        puts "detailer configs, and accounts.yaml."
        return
      end

      check_config!

      accounts = begin
        Accounts.new.all
      rescue ArgumentError
        []
      end

      UI.frame("Rename account") do
        old_name = UI.ask_with_autocomplete("Current account:", accounts)
        return UI.puts("{{x}} No account specified") if old_name.nil? || old_name.empty?

        new_name = UI.ask_with_autocomplete("New name:", accounts)
        return UI.puts("{{x}} No new name specified") if new_name.nil? || new_name.empty?

        if old_name == new_name
          UI.puts "{{x}} Names are the same, nothing to do"
          return
        end

        renamer = AccountRenamer.new(old_name: old_name, new_name: new_name)
        result = renamer.preview

        total_beancount = result[:beancount].sum { |c| c[:count] }
        total_detailers = result[:detailers].sum { |c| c[:count] }
        total_accounts = result[:accounts_yaml].size

        if total_beancount == 0 && total_detailers == 0 && total_accounts == 0
          UI.puts "{{x}} No occurrences found for {{bold:#{old_name}}}"
          return
        end

        if result[:beancount].any?
          UI.puts "{{bold:Beancount files}}: #{result[:beancount].size} files, #{total_beancount} occurrences"
          result[:beancount].each do |change|
            UI.puts "  #{UI.short_path(change[:path])} (#{change[:count]})"
          end
        end

        if result[:detailers].any?
          UI.puts "{{bold:Detailers}}: #{result[:detailers].size} files, #{total_detailers} rules"
          result[:detailers].each do |change|
            UI.puts "  #{UI.short_path(change[:path])} (#{change[:count]})"
          end
        end

        if result[:accounts_yaml].any?
          UI.puts "{{bold:accounts.yaml}}: #{total_accounts} fields"
          result[:accounts_yaml].each do |change|
            UI.puts "  #{change[:account_key]}.#{change[:field]}"
          end
        end

        if UI.confirm("Apply changes?")
          renamer.apply!
          UI.puts "{{v}} Changes applied"
        end
      end
    end

    def run_split(args)
      options = {dry_run: false}

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: frijolero split [ACCOUNT] [--dry-run]"

        opts.on("--dry-run", "Show what would be done without modifying files") do
          options[:dry_run] = true
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit
        end
      end

      parser.parse!(args)
      check_config!

      beancount_file = Config.beancount_main_file
      unless beancount_file && File.exist?(beancount_file)
        warn "Beancount file not found. Set paths.beancount_main in ~/.frijolero/config.yaml"
        exit 1
      end

      splitter = TransactionSplitter.new(beancount_file: beancount_file)
      summary = splitter.summary

      if summary.empty?
        UI.puts "No inline transactions found."
        return
      end

      # Show summary
      total = summary.values.sum
      UI.frame("Summary: #{total} inline transactions") do
        summary.each do |account, count|
          UI.puts "  #{account}: #{count}"
        end
      end

      # Determine account key
      account_key = args.first
      unless account_key
        choosable = summary.keys.reject { |k| k == "Other" }
        if choosable.empty?
          UI.puts "No configured accounts to split."
          return
        end
        account_key = UI.ask_select("Which account do you want to split?", choosable)
      end

      # Run split
      UI.frame("Splitting: #{account_key}") do
        result = splitter.split(account_key: account_key, dry_run: options[:dry_run])

        if result[:matched] == 0
          UI.puts "No transactions found for #{account_key}"
          return
        end

        result[:groups].sort.each do |yymm, count|
          skip = result[:existing]&.include?(yymm) ? " {{x}} already exists" : ""
          UI.puts "  #{result[:prefix]}_#{yymm}.beancount: #{count} transactions#{skip}"
        end

        if options[:dry_run]
          UI.puts ""
          UI.puts "(dry run — no files modified)"
        else
          UI.puts ""
          UI.puts "{{v}} #{result[:extracted]} transactions extracted into #{result[:files]} files"
        end
      end
    end

    def check_config!
      return if Config.initialized?

      warn "Configuration not found. Run 'frijolero init' first."
      exit 1
    end
  end
end
