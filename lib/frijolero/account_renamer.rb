# frozen_string_literal: true

module Frijolero
  class AccountRenamer
    ACCOUNT_FIELDS = %w[account beancount_account counterpart_account interest_account tax_account gains_account].freeze

    attr_reader :old_name, :new_name

    def initialize(old_name:, new_name:)
      @old_name = old_name
      @new_name = new_name
    end

    def preview
      {
        beancount: beancount_changes.map { |c| {path: c[:path], count: c[:count]} },
        detailers: detailer_changes.map { |c| {path: c[:path], count: c[:count]} },
        accounts_yaml: accounts_yaml_changes
      }
    end

    def apply!
      (beancount_changes + detailer_changes).each do |change|
        File.write(change[:path], change[:content])
      end

      apply_accounts_yaml! if accounts_yaml_changes.any?
    end

    private

    def beancount_pattern
      @beancount_pattern ||= /(?<=\s|^)#{Regexp.escape(old_name)}(?=\s|$)/
    end

    def beancount_changes
      @beancount_changes ||= beancount_files.filter_map do |path|
        original = File.read(path)
        count = original.scan(beancount_pattern).size
        next if count == 0

        modified = original.gsub(beancount_pattern, new_name)
        {path: path, count: count, content: modified}
      end
    end

    def detailer_changes
      @detailer_changes ||= detailer_files.filter_map do |path|
        original = File.read(path)
        count = 0

        modified = original.gsub(yaml_account_pattern) do
          count += 1
          "#{$1}#{new_name}#{$2}"
        end

        next if count == 0
        {path: path, count: count, content: modified}
      end
    end

    def accounts_yaml_changes
      @accounts_yaml_changes ||= begin
        path = Config.accounts_file
        return [] unless File.exist?(path)

        data = YAML.load_file(path) || {}
        changes = []

        data.each do |key, values|
          next unless values.is_a?(Hash)

          ACCOUNT_FIELDS.each do |field|
            changes << {account_key: key, field: field} if values[field] == old_name
          end
        end

        changes
      end
    end

    def apply_accounts_yaml!
      path = Config.accounts_file
      original = File.read(path)
      modified = original.gsub(yaml_account_pattern) do
        "#{$1}#{new_name}#{$2}"
      end
      File.write(path, modified)
    end

    def yaml_account_pattern
      @yaml_account_pattern ||= /^(\s*(?:#{ACCOUNT_FIELDS.join("|")}):\s*"?)#{Regexp.escape(old_name)}("?\s*)$/
    end

    def beancount_files
      files = Set.new

      acc_file = Config.beancount_accounts_file
      files << acc_file if acc_file && File.exist?(acc_file)

      main_file = Config.beancount_main_file
      if main_file && File.exist?(main_file)
        main_dir = File.dirname(main_file)
        Dir.glob(File.join(main_dir, "**", "*.beancount")).each { |f| files << f }
      end

      files.to_a
    end

    def detailer_files
      Dir.glob(File.join(Config.detailers_dir, "*.yaml"))
    end
  end
end
