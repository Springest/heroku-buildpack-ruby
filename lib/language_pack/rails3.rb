require "language_pack"
require "language_pack/rails2"

# Rails 3 Language Pack. This is for all Rails 3.x apps.
class LanguagePack::Rails3 < LanguagePack::Rails2
  # detects if this is a Rails 3.x app
  # @return [Boolean] true if it's a Rails 3.x app
  def self.use?
    instrument "rails3.use" do
      rails_version = bundler.gem_version('railties')
      return false unless rails_version
      is_rails3 = rails_version >= Gem::Version.new('3.0.0') &&
                  rails_version <  Gem::Version.new('4.0.0')
      return is_rails3
    end
  end

  def name
    "Ruby/Rails"
  end

  def default_process_types
    instrument "rails3.default_process_types" do
      # let's special case thin here
      web_process = bundler.has_gem?("thin") ?
        "bundle exec thin start -R config.ru -e $RAILS_ENV -p $PORT" :
        "bundle exec rails server -p $PORT"

      super.merge({
        "web" => web_process,
        "console" => "bundle exec rails console"
      })
    end
  end

  def compile
    instrument "rails3.compile" do
      super
    end
  end

private

  def install_plugins
    instrument "rails3.install_plugins" do
      return false if bundler.has_gem?('rails_12factor')
      plugins = {"rails_log_stdout" => "rails_stdout_logging", "rails3_serve_static_assets" => "rails_serve_static_assets" }.
                 reject { |plugin, gem| bundler.has_gem?(gem) }
      return false if plugins.empty?
      plugins.each do |plugin, gem|
        warn "Injecting plugin '#{plugin}'"
      end
      warn "Add 'rails_12factor' gem to your Gemfile to skip plugin injection"
      LanguagePack::Helpers::PluginsInstaller.new(plugins.keys).install
    end
  end

  # runs the tasks for the Rails 3.1 asset pipeline
  def run_assets_precompile_rake_task
    run_custom_build_steps :before_assets_precompile

    return true if load_assets_cache

    instrument "rails3.run_assets_precompile_rake_task" do
      log("assets_precompile") do
        if File.exists?("public/assets/manifest.yml")
          puts "Detected manifest.yml, assuming assets were compiled locally"
          return true
        end

        precompile = rake.task("assets:precompile")
        return true unless precompile.is_defined?

        topic("Preparing app for Rails asset pipeline")

        if user_env_hash.empty?
          default_env = {
            "RAILS_GROUPS" => ENV["RAILS_GROUPS"] || "assets",
            "RAILS_ENV"    => ENV["RAILS_ENV"]    || "production",
            "DATABASE_URL" => ENV["DATABASE_URL"] || default_database_url
          }
        else
          default_env = {
            "RAILS_GROUPS" => "assets",
            "RAILS_ENV"    => "production",
            "DATABASE_URL" => default_database_url
          }
        end

        precompile.invoke(env: default_env.merge(user_env_hash))

        if precompile.success?
          log "assets_precompile", :status => "success"
          puts "Asset precompilation completed (#{"%.2f" % precompile.time}s)"

          cache.store assets_cache

          FileUtils.mkdir_p(heroku_metadata)
          @metadata.write(assets_version_cache, assets_version, false)
          @metadata.save

          run_custom_build_steps :after_assets_precompile
        else
          log "assets_precompile", :status => "failure"
          error "Precompiling assets failed."
        end
      end
    end
  end

  # runs the tasks for the Rails 3.1 asset pipeline
  def run_db_migrate_rake_task(rollback = false)
    run_custom_build_steps :before_database_migrations

    old_schema_version = 0
    old_schema_version = @metadata.read(schema_version_cache).chomp.to_i if @metadata.exists?(schema_version_cache)
    rollback = true if old_schema_version > schema_version
    old_schema_version = @metadata.read(rollback_schema_version_cache).chomp if @metadata.exists?(rollback_schema_version_cache) && rollback
    return true if schema_same_since?(old_schema_version)

    instrument "rails3.run_db_migrate_rake_task" do
      log("db_migrate") do

        migrate = rake.task("db:migrate")
        migrate = rake.task("db:rollback") if rollback

        return true unless migrate.is_defined?

        topic("Running database migrations") unless rollback
        topic("Rolling back database to version #{old_schema_version}")

        if user_env_hash.empty?
          default_env = {
            "RAILS_ENV"    => ENV["RAILS_ENV"]    || "production",
            "DATABASE_URL" => ENV["DATABASE_URL"] || default_database_url
          }
        else
          default_env = {
            "RAILS_ENV"    => "production",
            "DATABASE_URL" => default_database_url
          }
        end

        default_env['VERSION'] = old_schema_version if rollback

        migrate.invoke(env: default_env.merge(user_env_hash))

        if migrate.success?
          log "db_migrate", :status => "success"
          puts "Database migrations completed (#{"%.2f" % migrate.time}s)" unless rollback
          puts "Database rollback completed (#{"%.2f" % migrate.time}s)" if rollback

          FileUtils.mkdir_p(heroku_metadata)
          @metadata.write(rollback_schema_version_cache, old_schema_version, false)
          @metadata.write(schema_version_cache, schema_version, false) unless rollback
          @metadata.write(schema_version_cache, old_schema_version, false) if rollback
          @metadata.save

          run_custom_build_steps :after_database_migrations
        else
          log "db_migrate", :status => "failure"
          error "Database migrations failed." unless rollback
          warn "Database rollback failed." if rollback
        end
      end
    end
  end

  def assets_cache
    "public/assets"
  end

  def assets_version
    %x(tar c vendor/assets/ \
      app/assets/ \
      config/javascript_translations.yml \
      config/javascript.yml | md5sum -b).chomp.split(' ').first
  end

  def schema_version
    return 0 unless File.exists?('db/schema.rb')
    %x(cat db/schema.rb | grep ActiveRecord::Schema.define | sed -e 's/[a-z A-Z = \> \: \. \( \)]//g').chomp.to_i
  end

  def assets_version_cache
    "assets_version"
  end

  def schema_version_cache
    "schema_version"
  end

  def rollback_schema_version_cache
    "rollback_schema_version"
  end

  def heroku_metadata
    "vendor/heroku"
  end

  def load_assets_cache
    instrument "rails3.load_assets_cache" do
      puts "Loading assets cache..."

      old_assets_version    = nil

      old_assets_version = @metadata.read(assets_version_cache).chomp if @metadata.exists?(assets_version_cache)

      cache.load assets_cache

      if assets_same_since?(old_assets_version)
        puts "Assets already cached. Skipping precompilation."
        warn "Use FORCE_ASSETS_COMPILATION to force compilation of assets."
        return true
      else
        %x{rm public/assets/manifest.yml}
        puts "Assets have changed since the last time, continuing to precompilation."
        return false
      end
    end
  end

  def assets_same_since?(old_assets_version = nil)
    return false if old_assets_version.nil? || old_assets_version.empty?
    return false if ENV['FORCE_ASSETS_COMPILATION']

    old_assets_version == assets_version
  end

  def schema_same_since?(old_schema_version = nil)
    return false if ENV['FORCE_DATABASE_MIGRATIONS'] || old_schema_version == 0

    old_schema_version == schema_version
  end

  # generate a dummy database_url
  def default_database_url
    instrument "rails3.setup_database_url_env" do
      # need to use a dummy DATABASE_URL here, so rails can load the environment
      scheme =
        if bundler.has_gem?("pg") || bundler.has_gem?("jdbc-postgres")
          "postgres"
      elsif bundler.has_gem?("mysql")
        "mysql"
      elsif bundler.has_gem?("mysql2")
        "mysql2"
      elsif bundler.has_gem?("sqlite3") || bundler.has_gem?("sqlite3-ruby")
        "sqlite3"
      end
      "#{scheme}://user:pass@127.0.0.1/dbname"
    end
  end
end
