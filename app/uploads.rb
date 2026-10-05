# frozen_string_literal: true

require 'fileutils'
require 'date'

module Frijolero
  # Upload a PDF, confirm the classification, enqueue the job. The uploads wait in the
  # Bandeja (Inbox) until a person confirms them.
  class App
    # The Bandeja's word and glyph for each status. ▲ needs a person; ■ failed.
    INBOX_STATUS = { classifying: %w[running clasificando], ready: %w[ok listo],
                     error: ['failed', 'no se clasificó'], failed: %w[failed falló],
                     unknown: ['missing', 'sin identificar'], exists: ['missing', 'ya existe'],
                     repeated: %w[missing repetido] }.freeze

    # No account, no upload: the classifier would spend a model call and the
    # confirm page could not name an account.
    before '/upload*' do
      redirect '/accounts/new', 303 if Config.accounts.empty?
    end

    get '/upload' do
      erb :upload
    end

    post '/upload' do
      item = save_upload
      result = Classifier.new(client: self.class.client).classify(item.pdf)
      self.class.inbox.record(item.token, result.to_h)
      erb :confirm, locals: {
        token: item.token,
        filename: item.filename,
        result: result,
        accounts: Config.accounts.keys,
        overwrite: params[:overwrite] ? '1' : '0'
      }
    rescue Classifier::NoClient
      self.class.inbox.record(item.token, error: "Falta #{LLM.key_var}")
      halt 422, "Falta #{LLM.key_var}: sin ella, el nombre del archivo tiene que ser \"Clave YYMM.pdf\""
    end

    # The share sheet's way in (an iOS Shortcut); Login checks the token. Every answer is
    # JSON, the errors too: a Shortcut reads a body more easily than a status.
    post '/api/upload' do
      content_type :json
      halt 422, JSON.generate(error: 'Primero da de alta una cuenta') if Config.accounts.empty?
      source, name = uploaded_pdf
      halt 422, JSON.generate(error: 'Sube un PDF') unless source

      self.class.inbox_worker.push(self.class.inbox.add(source, name).token)
      status 202
      JSON.generate(inbox: url('/inbox'))
    end

    get '/inbox' do
      erb :inbox, locals: { rows: inbox_rows }
    end

    # One button for one row and for "Procesar los listos": `tokens` lists the rows,
    # and each row sends its own account[token], period[token] and overwrite[token].
    post '/inbox/process' do
      halt 422, "Falta #{LLM.key_var}: la extracción la necesita" unless self.class.client
      choices = params[:tokens].to_s.split.uniq.map { |token| inbox_choice(token) }
      halt 422, 'Nada que procesar' if choices.empty?

      jobs = choices.map { |choice| enqueue_inbox(*choice) }
      redirect(jobs.one? ? "/jobs/#{jobs.first.id}" : '/jobs', 303)
    end

    post '/inbox/backup' do
      item, account, period = inbox_choice(params[:token])
      backup_pdf(account, period, item.pdf)
      redirect '/inbox', 303
    end

    post '/inbox/discard' do
      self.class.inbox.discard(inbox_item!(params[:token]).token)
      redirect '/inbox', 303
    end

    post '/upload/confirm' do
      halt 422, "Falta #{LLM.key_var}: la extracción la necesita" unless self.class.client
      account, period, pdf_path, overwrite = validate_confirm!
      period_end = iso_date(params[:period_end])
      job = enqueue_statement(account: account, period: period, pdf_path: pdf_path, overwrite: overwrite) do
        AccountConfig.record_cutoff(account, period_end) if period_end
      end
      redirect "/jobs/#{job.id}", 303
    end

    # Only the PDF, for a statement whose .beancount already exists. No model, no ledger,
    # no job: the put takes seconds, so it runs in the request.
    post '/upload/backup' do
      account, period = validate_account_and_period!
      backup_pdf(account, period, validate_token!(params[:token]))
      redirect "/accounts/#{Rack::Utils.escape_path(account)}", 303
    end

    private

    # One directory per upload (named by a random token) so the original filename
    # survives, which is what lets Classifier's filename shortcut fire.
    def save_upload
      source, name = uploaded_pdf
      halt 422, 'Sube un PDF' unless source

      self.class.inbox.add(source, name)
    end

    # [the temp file, the original name] of the uploaded PDF, or nil.
    def uploaded_pdf
      file = params[:pdf]
      name = upload_name(file)
      [file[:tempfile].path, name] if name.match?(/\.pdf\z/i)
    end

    # Rack leaves a plain multipart filename as BINARY; browsers send it as UTF-8.
    def upload_name(file)
      return '' unless file.is_a?(Hash)

      file[:filename].to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def validate_confirm!
      account, period = validate_account_and_period!
      [account, period, validate_token!(params[:token]), params[:overwrite] == '1']
    end

    def validate_account_and_period!(account = params[:account], period = params[:period])
      halt 422, 'Cuenta inválida' unless Config.accounts.key?(account)
      halt 422, 'Periodo inválido' unless period.to_s.match?(/\A\d{4}\z/)

      [account, period]
    end

    def validate_token!(token) = inbox_item!(token).pdf

    def inbox_item!(token)
      self.class.inbox.find(token) || halt(422, 'Token inválido')
    end

    # Only the PDF, in the request: the put takes seconds. The upload goes when it is safe.
    def backup_pdf(account, period, pdf_path)
      self.class.s3.put(Config.pdf_key(account, period), pdf_path)
      FileUtils.rm_rf(File.dirname(pdf_path))
    rescue S3::Error => e
      halt 502, "No se pudo guardar el PDF: #{Rack::Utils.escape_html(e.message)}"
    end

    def inbox_rows = self.class.inbox.rows(self.class.jobs.all)

    # [item, account, period, overwrite] of one Bandeja row, or a 422.
    def inbox_choice(token)
      item = inbox_item!(token)
      account, period = validate_account_and_period!(row_param(:account, token), row_param(:period, token))
      [item, account, period, row_param(:overwrite, token) == '1']
    end

    def row_param(name, token) = params[name].is_a?(Hash) ? params[name][token] : nil

    # The choice becomes the answer, so a row whose job fails comes back as the person
    # left it. The printed period end, when there is one, fills in the cutoff day.
    def enqueue_inbox(item, account, period, overwrite)
      answer = (item.answer || {}).except('error').merge('account' => account, 'period' => period)
      self.class.inbox.record(item.token, answer)
      period_end = iso_date(answer['period_end'])
      enqueue_statement(account: account, period: period, pdf_path: item.pdf, overwrite: overwrite) do
        AccountConfig.record_cutoff(account, period_end) if period_end
      end
    end

    # The printed period end is optional: the filename shortcut has none.
    def iso_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    # The collaborators are read here rather than inside the block: the block runs on
    # the worker thread, long after this request is gone.
    def enqueue_statement(account:, period:, pdf_path:, overwrite:, &after)
      statement = Statement.new(pdf_path, client: self.class.client, s3: self.class.s3, account: account,
                                          period: period, overwrite: overwrite)
      run_job("#{account} #{period}", statement, File.dirname(pdf_path), &after)
    end

    # Pull before the work and push after it, so the statement is written on top of
    # the latest ledger; a job that fails leaves the upload where it is, for a retry.
    # The block runs after a good statement and rides on the same commit.
    def run_job(label, statement, upload_dir)
      repo = self.class.repo
      self.class.jobs.push(label: label, token: File.basename(upload_dir)) do
        repo.pull
        status = statement.process
        raise "Statement terminó con #{status}" unless status == Statement::OK

        yield if block_given?
        repo.commit_and_push(label)
        FileUtils.rm_rf(upload_dir)
      end
    end
  end
end
