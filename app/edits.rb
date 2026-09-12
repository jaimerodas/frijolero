# frozen_string_literal: true

module Frijolero
  # The edit dialog of the journal. Reopens App to keep reports.rb the reports.
  class App
    helpers do
      # The journal reports absolute paths; the edit dialog works in ledger-relative ones.
      def ledger_relative(file)
        file.to_s.delete_prefix("#{File.expand_path(Config.ledger_dir)}/")
      end

      # `file` and `line` are checked by LedgerEdit itself: the trust boundary for both.
      def ledger_edit
        LedgerEdit.new(file: params[:file], line: params[:line], checker: self.class.reports)
      end
    end

    # One transaction as text, by file and line, or the whole file without a
    # line: {first, last, text}.
    get '/edit' do
      block = ledger_edit.block
      content_type :json
      JSON.generate(block)
    rescue LedgerEdit::NotFound
      halt 404, 'No existe esa transacción'
    end

    # The save writes the block, checks the whole ledger, and commits and pushes.
    # A failed check is 422 with the errors as JSON, so the editor can mark the
    # lines; every other failure is plain text. The file is back as it was on
    # 422, and saved but only committed locally on 502.
    post '/edit' do
      edit = ledger_edit
      text = edit.save(original: params[:original], edited: params[:content])
      self.class.repo.commit_and_push(edit.commit_message(original: params[:original], edited: text))
      status 204
    rescue LedgerEdit::NotFound
      halt 404, 'No existe esa transacción'
    rescue LedgerEdit::Stale
      halt 409, 'El archivo cambió en el ledger. Cancela y vuelve a abrirlo.'
    rescue LedgerEdit::Invalid => e
      content_type :json
      halt 422, JSON.generate(errors: e.errors)
    rescue Reports::Error => e
      halt 502, "No se pudo validar el ledger: #{e.message}"
    rescue LedgerRepo::Error => e
      halt 502, "Guardado en el servidor, pero no se pudo subir: #{e.message}"
    end

    # The editor page of any `.beancount` file of the ledger, where an error of
    # another file sends the person. The path checks are LedgerEdit's.
    get '/files/*' do
      file = params[:splat].first
      edit = LedgerEdit.new(file: file, line: nil, checker: self.class.reports)
      erb :file, locals: { file: file, text: edit.block[:text], statement: edit.statement,
                           notice: ('Guardado' if params[:saved]) }
    rescue LedgerEdit::NotFound
      halt 404, 'No existe ese archivo'
    end
  end
end
