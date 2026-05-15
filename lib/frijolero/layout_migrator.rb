# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Frijolero
  class LayoutMigrator
    CopyPair = Struct.new(:src, :dst, :kind, keyword_init: true)
    Redundant = Struct.new(:src, :dst, keyword_init: true)
    Conflict = Struct.new(:src, :dst, :reason, keyword_init: true)
    Unhandled = Struct.new(:path, :reason, keyword_init: true)
    Warning = Struct.new(:src, :prefix, keyword_init: true)
    ExecutionOutcome = Struct.new(:completed, :extra_conflicts, keyword_init: true)

    LEGACY_OLD_ROOT_SUBDIRS = %w[beancount json processed].freeze
    LEGACY_NEW_ROOT_SUBDIRS = %w[transactions].freeze
    KNOWN_OPTIONS = %i[apply prompt io stdin].freeze

    class AbortError < StandardError; end

    def initialize(old_root:, new_root:, main_file:, **options)
      reject_unknown_options(options)
      @old_root = File.expand_path(old_root)
      @new_root = File.expand_path(new_root)
      @main_file = main_file && File.expand_path(main_file)
      @apply = options.fetch(:apply, false)
      @prompt = options.fetch(:prompt, true)
      @io = options.fetch(:io, $stdout)
      @stdin = options.fetch(:stdin, $stdin)
    end

    def run
      plan = PlanBuilder.new(old_root: @old_root, new_root: @new_root).build
      formatter.print_plan(plan)
      return :dry_run unless @apply

      outcome = perform_copies(plan)
      verify_copies(outcome.completed)
      backup_path = rewrite_main_file!(outcome.completed)
      formatter.print_summary(plan, outcome, backup_path)
      maybe_delete(plan, outcome)
    rescue AbortError => e
      @io.puts "Migration aborted: #{e.message}"
      :aborted
    end

    private

    def reject_unknown_options(options)
      unknown = options.keys - KNOWN_OPTIONS
      raise ArgumentError, "unknown options: #{unknown.join(', ')}" unless unknown.empty?
    end

    def formatter
      @formatter ||= PlanFormatter.new(io: @io, old_root: @old_root, new_root: @new_root, main_file: @main_file)
    end

    def perform_copies(plan)
      outcome = ExecutionOutcome.new(completed: [], extra_conflicts: [])
      plan.copies.each { |pair| copy_one(pair, outcome) }
      outcome
    end

    def copy_one(pair, outcome)
      FileUtils.mkdir_p(File.dirname(pair.dst))
      if blocked?(pair)
        outcome.extra_conflicts << blocked_conflict(pair)
      else
        FileUtils.cp(pair.src, pair.dst) unless File.exist?(pair.dst)
        outcome.completed << pair
      end
    end

    def blocked?(pair)
      File.exist?(pair.dst) && !FileCompare.bytes_equal?(pair.src, pair.dst)
    end

    def blocked_conflict(pair)
      Conflict.new(src: pair.src, dst: pair.dst,
                   reason: 'destination already exists with different contents')
    end

    def verify_copies(completed)
      completed.each do |pair|
        src_sha = Digest::SHA256.file(pair.src).hexdigest
        dst_sha = Digest::SHA256.file(pair.dst).hexdigest
        next if src_sha == dst_sha

        raise AbortError, "verification failed for #{pair.dst} (expected #{src_sha}, got #{dst_sha})"
      end
    end

    def rewrite_main_file!(completed)
      return nil unless @main_file && File.exist?(@main_file)

      backup_path = "#{@main_file}.bak.#{Time.now.strftime('%Y%m%d_%H%M%S')}"
      FileUtils.cp(@main_file, backup_path)

      File.write(@main_file, rewritten_main_contents(completed))
      verify_main_file_includes!(backup_path)
      backup_path
    end

    def rewritten_main_contents(completed)
      map = transactions_rewrite_map(completed)
      File.read(@main_file).gsub(/include\s+"([^"]+)"/) { rewrite_include(Regexp.last_match, map) }
    end

    def rewrite_include(match, map)
      path = match[1]
      return %(include "#{map[path]}") if map.key?(path)
      return %(include "#{path.sub(%r{\Atransactions/}, '')}") if path.start_with?('transactions/')

      match[0]
    end

    # transactions/{prefix}/{old_basename}.beancount → {canonical}/{canonical_basename}.beancount
    def transactions_rewrite_map(completed)
      completed.each_with_object({}) do |pair, map|
        next unless pair.kind == :transactions

        map[relative_to_new_root(pair.src)] = relative_to_new_root(pair.dst)
      end
    end

    def relative_to_new_root(path)
      path.sub(%r{\A#{Regexp.escape(@new_root)}/}, '')
    end

    def verify_main_file_includes!(backup_path)
      dangling = dangling_includes
      return if dangling.empty?

      FileUtils.cp(backup_path, @main_file)
      raise AbortError,
            "rewritten main.beancount has #{dangling.size} dangling include(s); restored from #{backup_path}"
    end

    def dangling_includes
      main_dir = File.dirname(@main_file)
      File.readlines(@main_file).filter_map do |line|
        next unless (m = line.match(/^include\s+"(.+)"\s*$/))

        m[1] unless File.exist?(File.expand_path(m[1], main_dir))
      end
    end

    def maybe_delete(plan, outcome)
      return :kept unless @prompt
      return :kept unless confirm_delete?

      delete_originals(plan, outcome)
      :deleted
    end

    def confirm_delete?
      @io.puts 'Delete originals at:'
      @io.puts "  #{@old_root}/{#{LEGACY_OLD_ROOT_SUBDIRS.join(',')}}"
      @io.puts "  #{@new_root}/{#{LEGACY_NEW_ROOT_SUBDIRS.join(',')}}"
      @io.print 'Type "yes" to confirm: '
      @io.flush
      @stdin.gets&.strip == 'yes'
    end

    def delete_originals(plan, outcome)
      outcome.completed.each { |pair| FileUtils.rm_f(pair.src) }
      plan.redundants.each { |r| FileUtils.rm_f(r.src) }
      cleanup_empty_subdirs
      @io.puts 'Originals removed.'
    end

    def cleanup_empty_subdirs
      LEGACY_OLD_ROOT_SUBDIRS.each { |sub| prune_subdir(@old_root, sub) }
      LEGACY_NEW_ROOT_SUBDIRS.each { |sub| prune_subdir(@new_root, sub) }
    end

    def prune_subdir(root, sub)
      base = File.join(root, sub)
      return unless Dir.exist?(base)

      Dir.glob(File.join(base, '*')).each do |entry|
        Dir.rmdir(entry) if Dir.exist?(entry) && Dir.empty?(entry)
      end
      Dir.rmdir(base) if Dir.empty?(base)
    end
  end
end

require_relative 'layout_migrator/file_compare'
require_relative 'layout_migrator/plan'
require_relative 'layout_migrator/plan_builder'
require_relative 'layout_migrator/plan_formatter'
