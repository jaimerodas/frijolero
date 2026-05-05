# frozen_string_literal: true

require 'fileutils'

module Frijolero
  class TransactionSplitter
    OTHER = 'Other'

    def initialize(beancount_file:)
      @beancount_file = beancount_file
      @base_dir = File.dirname(beancount_file)
      @blocks = Beancount::Parser.parse(beancount_file)
    end

    def summary
      account_map = build_reverse_account_map
      counts = Hash.new(0)
      transaction_blocks.each { |block| counts[find_primary_account(block, account_map)] += 1 }
      counts.sort_by { |name, _| name == OTHER ? 'zzz' : name }.to_h
    end

    def split(account_key:, dry_run: false)
      target_account = lookup_target_account!(account_key)
      prefix = account_key.gsub(' ', '_')
      matched = transactions_matching(target_account)

      return empty_result if matched.empty?

      plan = build_plan(matched, prefix)
      result = build_result(matched, plan, prefix, target_account)

      return result.merge(extracted: 0, files: 0) if dry_run

      apply_plan(plan, prefix, result)
    end

    private

    def lookup_target_account!(account_key)
      account_config = AccountConfig.find_config(account_key)
      raise ArgumentError, "Account not found: #{account_key}" unless account_config

      account_config['beancount_account']
    end

    def transactions_matching(target_account)
      regex = /\b#{Regexp.escape(target_account)}\b/
      transaction_blocks.select { |b| b[:lines].any? { |l| l.match?(regex) } }
    end

    def empty_result
      { matched: 0, extracted: 0, files: 0, groups: {} }
    end

    def build_plan(matched, prefix)
      groups = matched.group_by { |b| date_to_yymm(b[:date]) }
      existing = groups.keys.select { |yymm| File.exist?(transactions_file(prefix, yymm)) }
      { groups: groups, existing: existing }
    end

    def build_result(matched, plan, prefix, target_account)
      {
        matched: matched.length,
        groups: plan[:groups].transform_values(&:length),
        existing: plan[:existing],
        prefix: prefix,
        target_account: target_account
      }
    end

    def apply_plan(plan, prefix, result)
      writable_groups = plan[:groups].except(*plan[:existing])
      return result.merge(extracted: 0, files: 0) if writable_groups.empty?

      backup_main_file
      write_transaction_files(writable_groups, prefix)
      Beancount::MainFileWriter.new(@beancount_file).rewrite(
        blocks: @blocks, extracted_groups: writable_groups, prefix: prefix
      )

      result.merge(extracted: writable_groups.values.sum(&:length), files: writable_groups.length)
    end

    def backup_main_file
      FileUtils.cp(@beancount_file, "#{@beancount_file}.bak")
    end

    def write_transaction_files(groups, prefix)
      transactions_dir = File.join(@base_dir, 'transactions', prefix)
      FileUtils.mkdir_p(transactions_dir)
      groups.sort.each do |yymm, txs|
        content = "#{txs.map { |t| t[:lines].join }.join.rstrip}\n"
        File.write(transactions_file(prefix, yymm), content)
      end
    end

    def transactions_file(prefix, yymm)
      File.join(@base_dir, 'transactions', prefix, "#{prefix}_#{yymm}.beancount")
    end

    def transaction_blocks
      @blocks.select { |b| b[:type] == :transaction }
    end

    def build_reverse_account_map
      Config.accounts.each_with_object({}) do |(key, config), map|
        beancount_account = config['beancount_account']
        map[beancount_account] = key if beancount_account
      end
    end

    def find_primary_account(block, account_map)
      block[:lines].each do |line|
        next unless line.match?(/^\s+/)

        account_map.each { |beancount_account, key| return key if line.include?(beancount_account) }
      end
      OTHER
    end

    def date_to_yymm(date)
      date[2, 2] + date[5, 2]
    end
  end
end
