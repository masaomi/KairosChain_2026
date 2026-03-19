# frozen_string_literal: true

module ServiceGrant
  class PgConnectionPool
    attr_reader :config

    def initialize(config = {}, circuit_breaker: nil)
      @config = config
      @circuit_breaker = circuit_breaker
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

    # Circuit breaker wraps at this level only (not exec_params).
    # This ensures all DB access paths are protected, including
    # direct with_connection calls from service_grant_migrate.
    def with_connection(&block)
      if @circuit_breaker
        @circuit_breaker.call { with_connection_raw(&block) }
      else
        with_connection_raw(&block)
      end
    end

    def exec_params(sql, params = [])
      with_connection { |conn| conn.exec_params(sql, params) }
    end

    # Skip circuit breaker for startup connection test.
    # Boot should fail fast on real PG outage, not be mediated by CB policy.
    def test_connection!
      with_connection_raw { |conn| conn.exec("SELECT 1") }
    end

    def close_all
      @mutex.synchronize do
        @pool.each { |c| c.close rescue nil }
        @pool.clear
      end
    end

    private

    def with_connection_raw
      conn = checkout
      yield conn
    ensure
      if conn
        conn.exec("ROLLBACK") if conn.transaction_status != PG::PQTRANS_IDLE rescue nil
        checkin(conn)
      end
    end

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
