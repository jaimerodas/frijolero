# frozen_string_literal: true

require 'sinatra/base'
require 'json'
require 'securerandom'
require 'fileutils'
require_relative 'jobs'
require_relative 'dashboard'
require_relative 'ledger_repo'

module Frijolero
  module Web
    class App < Sinatra::Base
      set :views, File.join(__dir__, 'views')
      set :public_folder, File.join(__dir__, 'public')
      set :static_cache_control, [:no_cache]

      # Set by the review flow
      set :json_file, nil
      set :beancount_account, nil
      set :accounts_list, []

      class << self
        attr_writer :jobs, :client, :b2

        def jobs = @jobs ||= Jobs.new(log_path: Config.jobs_file).tap(&:start)
        def client = @client ||= OpenAIClient.new
        def b2 = @b2 ||= B2.from_env
      end

      get '/' do
        failed = self.class.jobs.all.select { |j| j.status == 'failed' }.map(&:label)
        erb :dashboard, locals: { dashboard: Dashboard.new(failed: failed) }
      end

      get '/upload' do
        erb :upload
      end

      post '/upload' do
        path = save_upload
        result = Classifier.new(client: self.class.client).classify(path)
        erb :confirm, locals: {
          token: File.basename(File.dirname(path)),
          filename: File.basename(path),
          result: result,
          accounts: Config.accounts.keys,
          overwrite: params[:overwrite] ? '1' : '0'
        }
      end

      post '/upload/confirm' do
        account, period, pdf_path, file_id, overwrite = validate_confirm!
        job = enqueue_statement(account: account, period: period, pdf_path: pdf_path,
                                file_id: file_id, overwrite: overwrite)
        redirect "/jobs/#{job.id}", 303
      end

      get '/jobs' do
        erb :jobs, locals: { jobs: self.class.jobs.all }
      end

      get '/jobs/:id' do
        job = self.class.jobs.find(params[:id])
        halt 404, 'No existe ese job' unless job

        erb :job, locals: { job: job }
      end

      get '/statements/:account/:yymm/pdf' do
        halt 404, 'Cuenta desconocida' unless Config.accounts.key?(params[:account])
        halt 404, 'Periodo inválido' unless params[:yymm].match?(/\A\d{4}\z/)

        key = "accounts/#{params[:account]}/#{params[:account]} #{params[:yymm]}.pdf"
        redirect self.class.b2.presigned_url(key), 302
      end

      get '/review' do
        transactions = load_transactions
        erb :review, locals: {
          transactions: transactions,
          accounts: settings.accounts_list,
          filename: File.basename(settings.json_file),
          beancount_account: settings.beancount_account
        }
      end

      put '/transactions' do
        content_type :json
        data = JSON.parse(request.body.read)
        save_transactions(data['transactions'])
        { status: 'ok' }.to_json
      end

      post '/convert' do
        content_type :json
        data = JSON.parse(request.body.read)
        save_transactions(data['transactions'])

        output = Converters::Beancount.convert(
          input: settings.json_file,
          account: settings.beancount_account
        )

        { status: 'ok', output: output }.to_json
      end

      post '/convert-and-merge' do
        content_type :json
        data = JSON.parse(request.body.read)
        save_transactions(data['transactions'])

        beancount_path = Converters::Beancount.convert(
          input: settings.json_file,
          account: settings.beancount_account
        )

        BeancountMerger.new(
          files: [beancount_path],
          output: Config.main_file
        ).run

        { status: 'ok', output: beancount_path }.to_json
      end

      private

      def load_transactions
        JSON.parse(File.read(settings.json_file)).fetch('transactions', [])
      end

      def save_transactions(transactions)
        File.write(
          settings.json_file,
          JSON.pretty_generate({ 'transactions' => transactions })
        )
      end

      # One directory per upload (named by a random token) so the original filename
      # survives, which is what lets Classifier's filename shortcut fire.
      def save_upload
        file = params[:pdf]
        halt 422, 'Sube un PDF' unless file && file[:filename].to_s.match?(/\.pdf\z/i)

        dir = File.join(Config.incoming_dir, SecureRandom.hex(8))
        FileUtils.mkdir_p(dir)
        dest = File.join(dir, file[:filename])
        FileUtils.cp(file[:tempfile].path, dest)
        dest
      end

      def validate_confirm!
        account, period = validate_account_and_period!
        [account, period, validate_token!(params[:token]), blank_to_nil(params[:file_id]), params[:overwrite] == '1']
      end

      def validate_account_and_period!
        halt 422, 'Cuenta inválida' unless Config.accounts.key?(params[:account])
        halt 422, 'Periodo inválido' unless params[:period].to_s.match?(/\A\d{4}\z/)

        [params[:account], params[:period]]
      end

      def validate_token!(token)
        halt 422, 'Token inválido' unless token.to_s.match?(/\A\h{16}\z/)

        dir = File.join(Config.incoming_dir, token)
        files = Dir.exist?(dir) ? Dir.children(dir) : []
        halt 422, 'Token inválido' unless files.size == 1

        File.join(dir, files.first)
      end

      def blank_to_nil(value)
        value.to_s.strip.empty? ? nil : value
      end

      def enqueue_statement(account:, period:, pdf_path:, file_id:, overwrite:)
        upload_dir = File.dirname(pdf_path)
        client = self.class.client
        self.class.jobs.push(label: "#{account} #{period}") do
          status = Statement.new(pdf_path, client: client, account: account, period: period,
                                           file_id: file_id, overwrite: overwrite).process
          raise "Statement terminó con #{status}" unless status == Statement::OK

          FileUtils.rm_rf(upload_dir)
        end
      end
    end
  end
end

require_relative 'statements'
require_relative 'editors'
