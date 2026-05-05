# frozen_string_literal: true

module Frijolero
  class CLI
    class Rename
      include Helpers

      def self.call(args)
        new(args).call
      end

      def initialize(args)
        @args = args
      end

      def call
        return show_help if help_requested?

        check_config!
        accounts = accounts_for_autocomplete

        UI.frame('Rename account') do
          run_rename(accounts)
        end
      end

      private

      def help_requested?
        @args.include?('--help') || @args.include?('-h')
      end

      def show_help
        puts 'Usage: frijolero rename'
        puts
        puts 'Interactively rename an account across beancount files,'
        puts 'detailer configs, and accounts.yaml.'
      end

      def run_rename(accounts)
        old_name, new_name = ask_names(accounts)
        return unless old_name && new_name

        renamer = AccountRenamer.new(old_name: old_name, new_name: new_name)
        result = renamer.preview

        return UI.puts("{{x}} No occurrences found for {{bold:#{old_name}}}") if empty_result?(result)

        print_preview(result)
        apply_changes(renamer) if UI.confirm('Apply changes?')
      end

      def ask_names(accounts)
        old_name = UI.ask_with_autocomplete('Current account:', accounts)
        return UI.puts('{{x}} No account specified') if blank?(old_name)

        new_name = UI.ask_with_autocomplete('New name:', accounts)
        return UI.puts('{{x}} No new name specified') if blank?(new_name)

        if old_name == new_name
          UI.puts '{{x}} Names are the same, nothing to do'
          return
        end

        [old_name, new_name]
      end

      def blank?(value)
        value.nil? || value.empty?
      end

      def empty_result?(result)
        total_count(result[:beancount]).zero? &&
          total_count(result[:detailers]).zero? &&
          result[:accounts_yaml].empty?
      end

      def total_count(changes)
        changes.sum { |c| c[:count] }
      end

      def print_preview(result)
        print_path_changes('Beancount files', result[:beancount], 'occurrences')
        print_path_changes('Detailers', result[:detailers], 'rules')
        print_yaml_changes(result[:accounts_yaml])
      end

      def print_path_changes(label, changes, count_label)
        return if changes.empty?

        UI.puts "{{bold:#{label}}}: #{changes.size} files, #{total_count(changes)} #{count_label}"
        changes.each { |c| UI.puts "  #{UI.short_path(c[:path])} (#{c[:count]})" }
      end

      def print_yaml_changes(changes)
        return if changes.empty?

        UI.puts "{{bold:accounts.yaml}}: #{changes.size} fields"
        changes.each { |c| UI.puts "  #{c[:account_key]}.#{c[:field]}" }
      end

      def apply_changes(renamer)
        renamer.apply!
        UI.puts '{{v}} Changes applied'
      end
    end
  end
end
