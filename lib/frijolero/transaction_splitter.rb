# frozen_string_literal: true

require "set"
require "fileutils"

module Frijolero
  class TransactionSplitter
    def initialize(beancount_file:)
      @beancount_file = beancount_file
      @base_dir = File.dirname(beancount_file)
      @blocks = parse_file
    end

    def summary
      account_map = build_reverse_account_map
      counts = Hash.new(0)

      transaction_blocks.each do |block|
        account = find_primary_account(block, account_map)
        counts[account] += 1
      end

      counts.sort_by { |name, _| name == "Other" ? "zzz" : name }.to_h
    end

    def split(account_key:, dry_run: false)
      account_config = AccountConfig.find_config(account_key)
      raise ArgumentError, "Account not found: #{account_key}" unless account_config

      target_account = account_config["beancount_account"]
      prefix = account_key.gsub(" ", "_")
      transactions_dir = File.join(@base_dir, "transactions", prefix)

      account_regex = /\b#{Regexp.escape(target_account)}\b/
      matched = transaction_blocks.select { |b| b[:lines].any? { |l| l.match?(account_regex) } }

      return {matched: 0, extracted: 0, files: 0, groups: {}} if matched.empty?

      groups = matched.group_by { |b| date_to_yymm(b[:date]) }

      existing = groups.keys.select do |yymm|
        File.exist?(File.join(transactions_dir, "#{prefix}_#{yymm}.beancount"))
      end

      result = {
        matched: matched.length,
        groups: groups.transform_values(&:length),
        existing: existing,
        prefix: prefix,
        target_account: target_account
      }

      return result.merge(extracted: 0, files: 0) if dry_run

      groups.reject! { |yymm, _| existing.include?(yymm) }
      return result.merge(extracted: 0, files: 0) if groups.empty?

      # Backup
      FileUtils.cp(@beancount_file, @beancount_file + ".bak")

      # Write transaction files
      FileUtils.mkdir_p(transactions_dir)
      groups.sort.each do |yymm, txs|
        file = File.join(transactions_dir, "#{prefix}_#{yymm}.beancount")
        content = txs.map { |t| t[:lines].join }.join.rstrip + "\n"
        File.write(file, content)
      end

      # Rewrite main file
      rewrite_main_file(groups, prefix)

      result.merge(
        extracted: groups.values.sum(&:length),
        files: groups.length
      )
    end

    private

    def parse_file
      blocks = []
      lines = File.readlines(@beancount_file, encoding: "UTF-8")
      i = 0

      while i < lines.length
        line = lines[i]

        if line.match?(/^; === (Start|End): .+ ===$/)
          blocks << {type: :marker, lines: [line]}
          i += 1
          next
        end

        if line.match?(/^\d{4}-\d{2}-\d{2}\s+\*/)
          date = line[0, 10]
          tx_lines = [line]
          i += 1
          while i < lines.length
            if lines[i].match?(/^\s+\S/)
              tx_lines << lines[i]
              i += 1
            elsif lines[i].strip.empty?
              tx_lines << lines[i]
              i += 1
              break
            else
              break
            end
          end
          blocks << {type: :transaction, date: date, lines: tx_lines}
          next
        end

        blocks << {type: :other, lines: [line]}
        i += 1
      end

      blocks
    end

    def transaction_blocks
      @blocks.select { |b| b[:type] == :transaction }
    end

    def build_reverse_account_map
      map = {}
      Config.accounts.each do |key, config|
        beancount_account = config["beancount_account"]
        map[beancount_account] = key if beancount_account
      end
      map
    end

    def find_primary_account(block, account_map)
      block[:lines].each do |line|
        next unless line.match?(/^\s+/)
        account_map.each do |beancount_account, key|
          return key if line.include?(beancount_account)
        end
      end
      "Other"
    end

    def date_to_yymm(date)
      date[2, 2] + date[5, 2]
    end

    def rewrite_main_file(groups, prefix)
      extracted_ids = groups.values.flatten.map(&:object_id).to_set
      include_inserted = Set.new

      new_lines = []
      @blocks.each do |block|
        if block[:type] == :transaction && extracted_ids.include?(block.object_id)
          yymm = date_to_yymm(block[:date])
          unless include_inserted.include?(yymm)
            include_inserted.add(yymm)
            new_lines << "include \"transactions/#{prefix}/#{prefix}_#{yymm}.beancount\"\n"
          end
        elsif block[:type] == :marker
          next
        else
          new_lines.concat(block[:lines])
        end
      end

      # Collapse 3+ consecutive blank lines to 2
      cleaned = []
      blank_count = 0
      new_lines.each do |line|
        if line.strip.empty?
          blank_count += 1
          cleaned << line if blank_count <= 2
        else
          blank_count = 0
          cleaned << line
        end
      end

      File.write(@beancount_file, cleaned.join)
    end
  end
end
