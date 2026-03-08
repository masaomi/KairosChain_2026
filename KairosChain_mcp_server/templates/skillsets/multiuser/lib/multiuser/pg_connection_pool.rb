# frozen_string_literal: true

module Multiuser
  class PgConnectionPool
    TENANT_SCHEMA_PATTERN = /\Atenant_[0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12}\z/

    attr_reader :config

    def initialize(config = {})
      @config = config
      @pool = []
      @pool_size = config[:pool_size] || config['pool_size'] || 5
      @mutex = Mutex.new
      @timeout = config[:connect_timeout] || config['connect_timeout'] || 5
    end

    def checkout
      @mutex.synchronize do
        conn = @pool.pop
        if conn && conn.status == PG::CONNECTION_OK
          return conn
        end
        conn&.close rescue nil
      end
      create_connection
    end

    def checkin(conn)
      return unless conn
      @mutex.synchronize do
        if @pool.size < @pool_size && conn.status == PG::CONNECTION_OK
          @pool.push(conn)
        else
          conn.close rescue nil
        end
      end
    end

    # Execute a block with a connection scoped to a tenant schema.
    # Uses SET LOCAL inside a transaction so the search_path change
    # is automatically reverted on COMMIT/ROLLBACK.
    def with_tenant_connection(tenant_schema)
      validate_schema_name!(tenant_schema)
      conn = checkout
      conn.exec("BEGIN")
      conn.exec("SET LOCAL search_path TO #{PG::Connection.quote_ident(tenant_schema)}")
      result = yield conn
      conn.exec("COMMIT")
      result
    rescue => e
      conn&.exec("ROLLBACK") rescue nil
      raise
    ensure
      if conn
        conn.exec("ROLLBACK") if conn.transaction_status != PG::PQTRANS_IDLE rescue nil
        conn.exec("RESET search_path") rescue nil
        checkin(conn)
      end
    end

    # Execute a block with a connection on the public schema
    def with_connection
      conn = checkout
      yield conn
    ensure
      checkin(conn) if conn
    end

    def close_all
      @mutex.synchronize do
        @pool.each { |c| c.close rescue nil }
        @pool.clear
      end
    end

    def validate_schema_name!(schema)
      unless schema.match?(TENANT_SCHEMA_PATTERN)
        raise ArgumentError, "Invalid tenant schema: #{schema}"
      end
    end

    private

    def create_connection
      PG.connect(
        host: @config[:host] || @config['host'] || 'localhost',
        port: @config[:port] || @config['port'] || 5432,
        dbname: @config[:dbname] || @config['dbname'] || 'kairoschain',
        user: @config[:user] || @config['user'] || 'kairoschain',
        password: @config[:password] || @config['password'] || ENV['POSTGRES_PASSWORD'] || '',
        connect_timeout: @timeout
      )
    end
  end
end
