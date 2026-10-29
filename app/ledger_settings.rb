# frozen_string_literal: true

module Frijolero
  # /ledger: the settings of the current ledger. Its name, its remote, and an export.
  # A ledger with an origin never gets a deploy key here: its pulls already work, and a
  # new key would replace the one that its remote trusts.
  class App
    get('/ledger') { ledger_settings_page }

    post '/ledger/name' do
      name = Ledger.clean_name(params[:name])
      halt 422, ledger_settings_page(error: 'Falta el nombre del ledger.') if name.empty?

      save_ledger(name: name)
    end

    # The app appends to the main file, so it is one of the files that the page lists.
    post '/ledger/main' do
      main = params[:main_file].to_s
      unless main_files.include?(main)
        halt 422, ledger_settings_page(error: 'El archivo principal es un .beancount en la raíz del ledger.')
      end

      save_ledger(main_file: main)
    end

    # The first step of a remote: the key, which the page then shows with the URL form.
    post '/ledger/key' do
      Ledger.lock do
        halt 409, 'Este ledger ya tiene un remoto.' if self.class.repo.origin
        LedgerRepo.keygen(Ledger.current.deploy_key) unless File.exist?(Ledger.current.deploy_key)
      end
      redirect '/ledger', 303
    end

    # Without the key, ssh would push with whatever key it finds.
    post '/ledger/remote' do
      url = params[:url].to_s.strip
      Ledger.lock do
        halt 409, 'Este ledger ya tiene un remoto.' if self.class.repo.origin
        halt 409, 'Falta la llave del ledger.' unless File.exist?(Ledger.current.deploy_key)
        self.class.repo.add_remote(url)
        Ledger.update(Ledger.current.id, remote_url: url)
      end
      redirect '/ledger', 303
    rescue LedgerRepo::Error => e
      status 422
      ledger_settings_page(url: url, error: e.message)
    end

    # The name of the file keeps to ASCII letters, numbers, dots and dashes: Ñoño is Nono.
    # ponytail: the archive is built in memory, which a ledger of text files allows; stream
    # it if a ledger ever holds large files.
    get '/ledger/export' do
      name = Ledger.current.name.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').gsub(/[^\w.-]+/, '-')
      content_type 'application/gzip'
      attachment "#{name}.tar.gz"
      Ledger.lock { self.class.repo.archive }
    end

    helpers do
      # The choices for the main file: the .beancount files at the root of the ledger.
      def main_files
        dir = Config.ledger_dir
        Dir.glob('*.beancount', base: dir).select { |file| File.file?(File.join(dir, file)) }
      end

      # The origin without the user and password that an HTTPS URL can carry. The key and
      # the URL form show only while there is no origin and the key exists.
      def ledger_settings_page(url: nil, error: nil)
        ledger = Ledger.current
        origin = self.class.repo.origin&.sub(%r{//[^/@]*@}, '//')
        key = File.read("#{ledger.deploy_key}.pub").chomp if !origin && File.exist?(ledger.deploy_key)
        erb :ledger_settings, locals: { ledger: ledger, origin: origin, key: key, url: url, error: error }
      end

      # The row, then the name as `option "title"` of the main file: a new name, or a main
      # file that may not have it. The row is the name, so it stays when git fails, and the
      # commit goes up with the next push.
      def save_ledger(**fields)
        Ledger.update(Ledger.current.id, **fields)
        Ledger.current = Ledger.find(Ledger.current.id)
        commit_title
        redirect '/ledger', 303
      rescue LedgerRepo::Error => e
        status 502
        ledger_settings_page(error: "Guardado en el servidor, pero no se pudo subir: #{e.message}")
      end

      def commit_title
        Ledger.lock do
          NewLedger.write_title(Config.main_file, Ledger.current.name)
          self.class.repo.commit_and_push('Nombre del ledger')
        end
      end
    end
  end
end
