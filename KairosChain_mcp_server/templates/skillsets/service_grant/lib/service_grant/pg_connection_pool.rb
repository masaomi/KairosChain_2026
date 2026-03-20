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
      @cond = ConditionVariable.new
      @checked_out = 0
      @timeout = config[:connect_timeout] || config['connect_timeout'] || 5
    end

    # Bounded checkout: blocks when all connections are in use.
    # Prevents unbounded connection creation under concurrent load.
    def checkout
      @mutex.synchronize do
        loop do
          # Try to reuse a pooled connection
          conn = @pool.pop
          if conn
            if conn.status == PG::CONNECTION_OK
              @checked_out += 1
              return conn
            end
            conn.close rescue nil
            next
          end

          # Create new if under pool_size
          if @checked_out < @pool_size
            @checked_out += 1
            break  # create outside mutex
          end

          # Wait for a connection to be returned
          @cond.wait(@mutex, @timeout)
          raise PoolExhaustedError, "Connection pool exhausted (size: #{@pool_size})" if @checked_out >= @pool_size && @pool.empty?
        end
      end
      create_connection
    end

    def checkin(conn)
      return unless conn
      @mutex.synchronize do
        @checked_out -= 1
        if @pool.size < @pool_size && conn.status == PG::CONNECTION_OK
          @pool.push(conn)
        else
          conn.close rescue nil
        end
        @cond.signal  # wake one waiting checkout
      end
    end

    # Circuit breaker wraps at this level only (not exec_params).
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
    def test_connection!
      with_connection_raw { |conn| conn.exec("SELECT 1") }
    end

    def close_all
      @mutex.synchronize do
        @pool.each { |c| c.close rescue nil }
        @pool.clear
        @checked_out = 0
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
