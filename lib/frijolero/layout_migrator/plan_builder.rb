# frozen_string_literal: true

module Frijolero
  class LayoutMigrator
    class PlanBuilder
      def initialize(old_root:, new_root:)
        @old_root = old_root
        @new_root = new_root
        @copies = []
        @redundants = []
        @conflicts = []
        @unhandled = []
        @warnings = []
        @warned_prefixes = {}
        @transactions_dsts = {}
      end

      def build
        scan_transactions
        scan_beancount
        scan_json
        scan_processed
        Plan.new(copies: @copies, redundants: @redundants, conflicts: @conflicts,
                 unhandled: @unhandled, warnings: @warnings)
      end

      private

      def scan_transactions
        base = File.join(@new_root, 'transactions')
        return unless Dir.exist?(base)

        Dir.glob(File.join(base, '*', '*.beancount')).each do |src|
          dir_prefix = File.basename(File.dirname(src))
          canonical, known = canonical_for([parse_raw_prefix(src), dir_prefix])
          warn_unknown(src, canonical) unless known
          dst = prefix_dst(canonical, normalize_basename(src, canonical))
          @transactions_dsts[dst] = src
          register(src, dst, :transactions)
        end
      end

      def scan_beancount
        each_in('beancount', '*.beancount') do |src|
          handle_with_prefix(src) do |canonical|
            dst = prefix_dst(canonical, normalize_basename(src, canonical))
            existing = @transactions_dsts[dst]
            existing ? mark_duplicate(src, dst, existing) : register(src, dst, :beancount)
          end
        end
      end

      def scan_json
        each_in('json', '*.json') do |src|
          handle_with_prefix(src) do |canonical|
            dst = prefix_dst(canonical, 'json', normalize_basename(src, canonical))
            register(src, dst, :json)
          end
        end
      end

      def scan_processed
        each_in('processed', '*.pdf') do |src|
          parsed = AccountConfig.parse_filename(src)
          next @unhandled << Unhandled.new(path: src, reason: 'unparseable PDF filename') unless parsed

          canonical, known = canonical_for([parsed[0]])
          warn_unknown(src, canonical) unless known
          dst_name = "#{canonical}_#{parsed[1]}.pdf"
          register(src, prefix_dst(canonical, 'pdf', dst_name), :pdf)
        end
      end

      def each_in(subdir, pattern, &block)
        base = File.join(@old_root, subdir)
        return unless Dir.exist?(base)

        Dir.glob(File.join(base, pattern)).each(&block)
      end

      def handle_with_prefix(src)
        raw = parse_raw_prefix(src)
        return @conflicts << Conflict.new(src: src, dst: nil, reason: 'unparseable filename') unless raw

        canonical, known = canonical_for([raw])
        warn_unknown(src, canonical) unless known
        yield canonical
      end

      # Tries each candidate against accounts.yaml, returns [canonical_prefix, known].
      # Falls back to the first non-nil candidate with spaces underscored.
      def canonical_for(candidates)
        candidates.compact.each do |c|
          canonical = AccountConfig.canonical_prefix(c)
          return [canonical, true] if canonical
        end
        [candidates.compact.first.to_s.gsub(' ', '_'), false]
      end

      def parse_raw_prefix(path)
        parsed = AccountConfig.parse_filename(path)
        parsed && parsed[0]
      end

      # Rebuilds a filename with the canonical prefix while preserving date + extension.
      def normalize_basename(src, canonical)
        parsed = AccountConfig.parse_filename(src)
        return File.basename(src) unless parsed

        "#{canonical}_#{parsed[1]}#{File.extname(src)}"
      end

      def warn_unknown(src, prefix)
        return if @warned_prefixes[prefix]

        @warned_prefixes[prefix] = true
        @warnings << Warning.new(src: src, prefix: prefix)
      end

      def prefix_dst(*parts)
        File.join(@new_root, *parts)
      end

      def register(src, dst, kind)
        @copies << CopyPair.new(src: src, dst: dst, kind: kind)
      end

      def mark_duplicate(src, dst, existing)
        if FileCompare.bytes_equal?(src, existing)
          @redundants << Redundant.new(src: src, dst: dst)
        else
          @conflicts << Conflict.new(src: src, dst: dst, reason: 'differs from transactions/ source')
        end
      end
    end
  end
end
