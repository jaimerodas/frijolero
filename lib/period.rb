# frozen_string_literal: true

require 'date'

module Frijolero
  # A report period from `?period=`: `all`, `2026`, `2026-T3` or `2026-09`.
  # `from` and `to` are the nominal bounds; a running period ends after today.
  class Period
    MONTHS = %w[enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre].freeze
    RESOLUTIONS = { all: 'Todo', year: 'Año', quarter: 'Trimestre', month: 'Mes' }.freeze

    attr_reader :resolution, :from, :to

    PARAM_RE = /\A(?<year>\d{4})(?:-(?:T(?<quarter>[1-4])|(?<month>\d{2})))?\z/

    # nil for anything that is not a period, so the caller can fall back.
    def self.parse(param, first:, today:)
      return new(:all, first, today) if param == 'all'

      match = PARAM_RE.match(param.to_s)
      match && of(Date.new(match[:year].to_i, first_month(match), 1), resolution_of(match))
    rescue Date::Error
      nil
    end

    def self.resolution_of(match)
      %i[quarter month].find { |name| match[name] } || :year
    end

    def self.first_month(match)
      match[:quarter] ? (match[:quarter].to_i * 3) - 2 : (match[:month] || 1).to_i
    end

    MONTHS_PER = { year: 12, quarter: 3, month: 1 }.freeze

    # The period at `resolution` that holds `date`. `all` spans the ledger.
    def self.of(date, resolution, first: nil, today: nil)
      return new(:all, first, today) if resolution == :all

      months = MONTHS_PER.fetch(resolution)
      start = Date.new(date.year, ((date.month - 1) / months * months) + 1, 1)
      new(resolution, start, (start >> months) - 1)
    end

    def initialize(resolution, from, to)
      @resolution = resolution
      @from = from
      @to = to
    end

    def param
      case resolution
      when :all then 'all'
      when :year then from.year.to_s
      when :quarter then "#{from.year}-T#{quarter}"
      when :month then from.strftime('%Y-%m')
      end
    end

    def label
      case resolution
      when :all then 'Todo'
      when :year then from.year.to_s
      when :quarter then "T#{quarter} #{from.year}"
      when :month then "#{MONTHS[from.month - 1]} #{from.year}"
      end
    end

    def quarter
      ((from.month - 1) / 3) + 1
    end

    # The same span at another resolution: the period that holds this one's
    # last day, or today when this one is still running.
    def at(new_resolution, first:, today:)
      Period.of([to, today].min, new_resolution, first: first, today: today)
    end

    # Neighbours at this resolution, nil past the ledger's bounds and for `all`.
    def prev(first:)
      Period.of(from - 1, resolution) if resolution != :all && from > first
    end

    def next(today:)
      Period.of(to + 1, resolution) if resolution != :all && to < today
    end

    # Every period at this resolution from the ledger's first day to today, newest first.
    def siblings(first:, today:)
      return [self] if resolution == :all

      list = []
      period = Period.of(today, resolution)
      while period.to >= first
        list << period
        period = Period.of(period.from - 1, resolution)
      end
      list
    end
  end
end
