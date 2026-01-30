# frozen_string_literal: true

require 'securerandom'
require 'time'

module KairosMcp
  module MeetingPlace
    # Message relay for encrypted message forwarding between agents.
    # IMPORTANT: This class NEVER decrypts or inspects message content.
    # It only stores and forwards encrypted blobs.
    class MessageRelay
      DEFAULT_TTL_SECONDS = 3600  # 1 hour
      DEFAULT_MAX_QUEUE_SIZE = 100
      DEFAULT_MAX_MESSAGE_SIZE = 1_048_576  # 1 MB

      attr_reader :config

      def initialize(config: {}, audit_logger: nil)
        @config = {
          ttl_seconds: config[:ttl_seconds] || DEFAULT_TTL_SECONDS,
          max_queue_size: config[:max_queue_size] || DEFAULT_MAX_QUEUE_SIZE,
          max_message_size: config[:max_message_size] || DEFAULT_MAX_MESSAGE_SIZE
        }
        @queues = {}  # agent_id => [messages]
        @mutex = Mutex.new
        @audit_logger = audit_logger
      end

      # Enqueue an encrypted message for a recipient
      # IMPORTANT: encrypted_blob is stored as-is, never decrypted
      def enqueue(from:, to:, encrypted_blob:, blob_hash:, message_type: 'unknown')
        validate_message!(encrypted_blob)
        
        message = {
          id: generate_message_id,
          from: from,
          to: to,
          message_type: message_type,
          encrypted_blob: encrypted_blob,
          blob_hash: blob_hash,
          size_bytes: encrypted_blob.bytesize,
          created_at: Time.now.utc.iso8601,
          expires_at: (Time.now.utc + @config[:ttl_seconds]).iso8601
        }

        @mutex.synchronize do
          @queues[to] ||= []
          
          # Check queue size limit
          if @queues[to].size >= @config[:max_queue_size]
            # Remove oldest message
            @queues[to].shift
          end
          
          @queues[to] << message
        end

        # Log to audit (metadata only, no content)
        log_audit(:enqueue, message)

        {
          relay_id: message[:id],
          status: 'queued',
          expires_at: message[:expires_at]
        }
      end

      # Dequeue messages for a recipient
      # Returns and removes messages from the queue
      def dequeue(recipient_id, limit: 10)
        cleanup_expired
        
        messages = @mutex.synchronize do
          queue = @queues[recipient_id] || []
          
          # Take up to 'limit' messages
          taken = queue.shift(limit)
          
          # Clean up empty queue
          @queues.delete(recipient_id) if queue.empty?
          
          taken
        end

        # Log each dequeue to audit
        messages.each do |msg|
          log_audit(:dequeue, msg)
        end

        {
          messages: messages.map { |m| sanitize_for_delivery(m) },
          count: messages.size
        }
      end

      # Peek at messages without removing them
      def peek(recipient_id, limit: 10)
        cleanup_expired
        
        @mutex.synchronize do
          queue = @queues[recipient_id] || []
          messages = queue.first(limit)
          
          {
            messages: messages.map { |m| sanitize_for_delivery(m) },
            count: messages.size,
            total_pending: queue.size
          }
        end
      end

      # Get statistics (no content, just counts)
      def stats
        cleanup_expired
        
        @mutex.synchronize do
          total_messages = @queues.values.sum(&:size)
          total_queues = @queues.size
          
          # Calculate size distribution without exposing content
          sizes = @queues.values.flatten.map { |m| m[:size_bytes] }
          
          {
            total_messages: total_messages,
            active_queues: total_queues,
            oldest_message: oldest_message_age,
            total_size_bytes: sizes.sum,
            average_size_bytes: sizes.empty? ? 0 : (sizes.sum / sizes.size),
            max_size_bytes: sizes.max || 0
          }
        end
      end

      # Clean up expired messages
      def cleanup_expired
        now = Time.now.utc
        
        @mutex.synchronize do
          @queues.each do |agent_id, queue|
            queue.reject! do |msg|
              expired = Time.parse(msg[:expires_at]) < now
              log_audit(:expired, msg) if expired
              expired
            end
          end
          
          # Remove empty queues
          @queues.delete_if { |_, queue| queue.empty? }
        end
      end

      # Get queue status for a specific agent
      def queue_status(agent_id)
        cleanup_expired
        
        @mutex.synchronize do
          queue = @queues[agent_id] || []
          
          {
            agent_id: agent_id,
            pending_count: queue.size,
            oldest_at: queue.first&.dig(:created_at),
            newest_at: queue.last&.dig(:created_at)
          }
        end
      end

      private

      def generate_message_id
        "relay_#{SecureRandom.hex(8)}"
      end

      def validate_message!(encrypted_blob)
        if encrypted_blob.nil? || encrypted_blob.empty?
          raise ArgumentError, 'Encrypted blob cannot be empty'
        end

        if encrypted_blob.bytesize > @config[:max_message_size]
          raise ArgumentError, "Message exceeds maximum size (#{@config[:max_message_size]} bytes)"
        end
      end

      # Sanitize message for delivery (remove internal fields)
      def sanitize_for_delivery(message)
        {
          id: message[:id],
          from: message[:from],
          message_type: message[:message_type],
          encrypted_blob: message[:encrypted_blob],
          blob_hash: message[:blob_hash],
          created_at: message[:created_at]
        }
      end

      def oldest_message_age
        oldest = nil
        
        @queues.each_value do |queue|
          next if queue.empty?
          
          msg_time = Time.parse(queue.first[:created_at])
          oldest = msg_time if oldest.nil? || msg_time < oldest
        end
        
        oldest ? (Time.now.utc - oldest).to_i : nil
      end

      def log_audit(action, message)
        return unless @audit_logger

        @audit_logger.log_relay(
          action: action,
          relay_id: message[:id],
          from: message[:from],
          to: message[:to],
          message_type: message[:message_type],
          blob_hash: message[:blob_hash],
          size_bytes: message[:size_bytes]
          # IMPORTANT: We never log encrypted_blob content
        )
      end
    end
  end
end
