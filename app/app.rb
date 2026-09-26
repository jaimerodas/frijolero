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

    JOB_STATUS = { 'queued' => 'en cola', 'running' => 'corriendo', 'ok' => 'listo', 'failed' => 'falló' }.freeze

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

      # 1234 → '1,234', '5276.79' → '5,276.79'. Display only.
      def thousands(number) = Converters::Amounts.group(number)

      # -1234.5 → '-1,234.50', 5276.79 → '+5,276.79'. Display only.
      def money(amount)
        return '' if amount.nil?

        "#{amount.negative? ? '-' : '+'}#{thousands(format('%.2f', amount.abs))}"
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

    # The job page and the Bitácora: Spanish status words, local time, and the check
    # behind the retry button (also run by the retry route itself).
    helpers do
      # 'queued' → 'en cola', etc. The dashboard has its own 'falló' for the same word.
      def job_status(status) = JOB_STATUS.fetch(status, status)

      # UTC ISO 8601 → local time, e.g. '4 sep 2026, 06:22'. TZ is the Dockerfile's job.
      def local_time(iso)
        return '' unless iso

        t = Time.iso8601(iso).localtime
        "#{t.day} #{Period::MONTHS[t.month - 1][0, 3]} #{t.year}, #{t.strftime('%H:%M')}"
      end

      # [account, period, pdf_path] for a failed job whose upload can still be retried,
      # or nil: it needs its token, the account, no statement yet, and the PDF still on disk.
      def retryable_upload(job)
        return nil unless job.status == 'failed' && job.token

        account, _, period = job.label.rpartition(' ')
        return nil unless Config.accounts.key?(account)
        return nil if File.exist?(Config.statement_path(account, period, 'beancount'))

        pdf_path = upload_pdf(job.token)
        pdf_path && [account, period, pdf_path]
      end
    end

    get '/' do
      # jobs.all is newest first, so uniq keeps the latest failure of each label.
      failed = self.class.jobs.all.select { |j| j.status == 'failed' }.uniq(&:label).to_h { |j| [j.label, j.id] }
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

    # Queues the same statement again from the upload directory a failed job left behind.
    post '/jobs/:id/retry' do
      job = self.class.jobs.find(params[:id])
      halt 404, 'No existe esa corrida' unless job
      halt 422, "Falta #{LLM.key_var}: la extracción la necesita" unless self.class.client

      account, period, pdf_path = retryable_upload(job)
      halt 422, 'Esta corrida no se puede reintentar' unless account

      new_job = enqueue_statement(account: account, period: period, pdf_path: pdf_path, overwrite: false)
      redirect "/jobs/#{new_job.id}", 303
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
require_relative 'errors'
