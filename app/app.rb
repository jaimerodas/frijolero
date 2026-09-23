# frozen_string_literal: true

require 'sinatra/base'
require_relative '../lib/frijolero'
require_relative 'jobs'
require_relative 'dashboard'

module Frijolero
  class App < Sinatra::Base
    set :views, File.join(__dir__, 'views')
    set :public_folder, File.expand_path('../public', __dir__)
    set :static_cache_control, [:no_cache]

    class << self
      attr_writer :jobs, :client, :s3, :repo, :reports

      def jobs = @jobs ||= Jobs.new(log_path: Config.jobs_file).tap(&:start)
      def client = @client ||= LLM.client
      # Any S3 variable set means S3; from_env then names the missing ones. None means disk.
      def s3 = @s3 ||= (S3::ENV_KEYS.any? { |k| ENV.key?(k) } ? S3.from_env : LocalPdfs.new(Config.pdfs_dir))
      def repo = @repo ||= LedgerRepo.new(dir: Config.ledger_dir)
      def reports = @reports ||= Reports
    end

    helpers do
      # The <head> every page shares. `refresh` adds a meta refresh in seconds.
      def head(title = Config.title, refresh: nil)
        erb :_head, layout: false, locals: { title: title, refresh: refresh }
      end

      # The header every page shares: wordmark and the two sections.
      def topbar
        erb :_topbar, layout: false
      end

      # Text into HTML, escaped. Every view writes its values through this.
      def h(text) = Rack::Utils.escape_html(text.to_s)

      # 'YYMM' → 'agosto 2026'. URLs and file names keep YYMM.
      def period_name(period)
        "#{Period::MONTHS[period[2, 2].to_i - 1]} 20#{period[0, 2]}"
      end

      # 1234 → '1,234'. Display only.
      def thousands(count)
        count.to_s.gsub(/\B(?=(\d{3})+\z)/, ',')
      end

      # -1234.5 → '-1,234.50', 5276.79 → '+5,276.79'. Display only.
      def money(amount)
        return '' if amount.nil?

        "#{amount.negative? ? '-' : '+'}#{format('%.2f', amount.abs).sub(/\d+/) { thousands(it) }}"
      end

      # Merchant first, the rest second: BBVA appends '; Fecha de cargo: …', AMEX appends ' RFC… /REF…'.
      def split_description(description)
        description.to_s.split(/; | (?=RFC[A-Z0-9]{6,})/, 2)
      end

      # Only the Default pipeline has rules: links, editor and the detail action.
      def rules?(account)
        Pipeline.for(Config.accounts[account]).runs_detailer?
      end
    end

    get '/' do
      failed = self.class.jobs.all.select { |j| j.status == 'failed' }.map(&:label)
      erb :dashboard, locals: { dashboard: Dashboard.new(failed: failed) }
    end

    get '/jobs' do
      erb :jobs, locals: { jobs: self.class.jobs.all }
    end

    get '/jobs/:id' do
      job = self.class.jobs.find(params[:id])
      halt 404, 'No existe esa corrida' unless job

      erb :job, locals: { job: job }
    end
  end
end

# Each file reopens App with the routes of one page, so app.rb stays a table of contents.
require_relative 'uploads'
require_relative 'statements'
require_relative 'editors'
require_relative 'accounts'
require_relative 'reports'
require_relative 'edits'
require_relative 'charts'
require_relative 'sorting'
