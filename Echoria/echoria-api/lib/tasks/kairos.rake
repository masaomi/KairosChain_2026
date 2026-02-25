namespace :kairos do
  desc "Create KairosChain tables (kairos_blocks, kairos_action_logs, kairos_knowledge_meta)"
  task setup: :environment do
    config = ActiveRecord::Base.connection_db_config.configuration_hash

    backend = KairosMcp::Storage::PostgresqlBackend.new(
      host: config[:host] || "localhost",
      port: config[:port] || 5432,
      dbname: config[:database],
      user: config[:username] || config[:user],
      password: config[:password],
      tenant_id: "__system__"
    )

    if backend.ready?
      puts "KairosChain tables created successfully."
    else
      puts "ERROR: Failed to create KairosChain tables."
      exit 1
    end
  end

  desc "Verify KairosChain integration is working"
  task verify: :environment do
    puts "Checking KairosChain integration..."

    # Check backend factory
    backend = KairosMcp::Storage::Backend.create("postgresql",
      host: "localhost",
      port: ENV.fetch("DB_PORT", 5432),
      dbname: ActiveRecord::Base.connection.current_database,
      user: ActiveRecord::Base.connection_db_config.configuration_hash[:username],
      password: ActiveRecord::Base.connection_db_config.configuration_hash[:password],
      tenant_id: "__verify__"
    )

    puts "  Backend type: #{backend.backend_type}"
    puts "  Ready: #{backend.ready?}"

    # Test basic operations
    backend.save_block(0, { test: true, timestamp: Time.now.iso8601 })
    blocks = backend.all_blocks
    puts "  Block count: #{blocks.length}"

    backend.record_action("verify", { message: "Integration test" })
    actions = backend.action_history
    puts "  Action count: #{actions.length}"

    # Cleanup
    backend.clear_action_log!
    puts "  Cleanup: done"

    puts "KairosChain integration verified."
  end
end
