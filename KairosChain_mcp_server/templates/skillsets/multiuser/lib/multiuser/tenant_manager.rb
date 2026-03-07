# frozen_string_literal: true

require 'securerandom'

module Multiuser
  class TenantManager
    attr_reader :pool

    def initialize(pool)
      @pool = pool
      @migrations_dir = File.join(File.dirname(__FILE__), '..', '..', 'migrations')
    end

    def create_tenant(name)
      schema = "tenant_#{SecureRandom.uuid.tr('-', '_')}"

      pool.with_connection do |conn|
        conn.exec("CREATE SCHEMA #{PG::Connection.quote_ident(schema)}")

        migration_file = File.join(@migrations_dir, '002_tenant_template.sql')
        if File.exist?(migration_file)
          sql = File.read(migration_file)
          conn.exec("SET search_path TO #{PG::Connection.quote_ident(schema)}")
          conn.exec(sql)
          conn.exec("RESET search_path")

          conn.exec_params(
            "INSERT INTO tenant_migrations (tenant_schema, version) VALUES ($1, $2)",
            [schema, '002_tenant_template']
          )
        end
      end

      schema
    end

    def list_tenants
      pool.with_connection do |conn|
        result = conn.exec(
          "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'tenant_%' ORDER BY schema_name"
        )
        result.map { |row| row['schema_name'] }
      end
    end

    def tenant_exists?(schema)
      pool.validate_schema_name!(schema)
      pool.with_connection do |conn|
        result = conn.exec_params(
          "SELECT 1 FROM information_schema.schemata WHERE schema_name = $1",
          [schema]
        )
        result.ntuples > 0
      end
    end

    def drop_tenant(schema)
      pool.validate_schema_name!(schema)
      pool.with_connection do |conn|
        conn.exec("DROP SCHEMA #{PG::Connection.quote_ident(schema)} CASCADE")
        conn.exec_params(
          "DELETE FROM tenant_migrations WHERE tenant_schema = $1",
          [schema]
        )
      end
    end

    # Run public schema migrations
    def migrate_public!
      migration_file = File.join(@migrations_dir, '001_public_schema.sql')
      return unless File.exist?(migration_file)

      pool.with_connection do |conn|
        already = begin
          conn.exec("SELECT version FROM system_migrations WHERE version = '001_public_schema'")
             .ntuples > 0
        rescue PG::UndefinedTable
          false
        end

        unless already
          conn.exec(File.read(migration_file))
          conn.exec_params(
            "INSERT INTO system_migrations (version) VALUES ($1)",
            ['001_public_schema']
          )
        end
      end
    end

    # List pending migrations for a tenant
    def pending_migrations(schema)
      pool.validate_schema_name!(schema)
      all = Dir[File.join(@migrations_dir, '*.sql')]
             .map { |f| File.basename(f, '.sql') }
             .select { |n| n.start_with?('002') }
             .sort

      applied = pool.with_connection do |conn|
        conn.exec_params(
          "SELECT version FROM tenant_migrations WHERE tenant_schema = $1",
          [schema]
        ).map { |r| r['version'] }
      end

      all - applied
    end

    # Run pending migrations for all tenants
    def migrate_all
      results = {}
      list_tenants.each do |schema|
        results[schema] = migrate_tenant(schema)
      end
      results
    end

    def migrate_tenant(schema)
      pending = pending_migrations(schema)
      return [] if pending.empty?

      applied = []
      pending.each do |version|
        file = File.join(@migrations_dir, "#{version}.sql")
        next unless File.exist?(file)

        pool.with_connection do |conn|
          conn.exec("SET search_path TO #{PG::Connection.quote_ident(schema)}")
          conn.exec(File.read(file))
          conn.exec("RESET search_path")

          conn.exec_params(
            "INSERT INTO tenant_migrations (tenant_schema, version) VALUES ($1, $2)",
            [schema, version]
          )
        end
        applied << version
      end
      applied
    end
  end
end
