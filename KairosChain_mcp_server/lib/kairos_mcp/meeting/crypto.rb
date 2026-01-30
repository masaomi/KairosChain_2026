# frozen_string_literal: true

require 'openssl'
require 'base64'
require 'digest'
require 'json'
require 'fileutils'

module KairosMcp
  module Meeting
    # End-to-End encryption for Meeting Protocol communications.
    # Implements RSA-2048 for key exchange and AES-256-GCM for message encryption.
    # This hybrid approach allows efficient encryption of large messages.
    class Crypto
      DEFAULT_RSA_BITS = 2048
      AES_KEY_BITS = 256
      AES_CIPHER = 'aes-256-gcm'
      
      attr_reader :public_key, :private_key

      def initialize(keypair_path: nil, auto_generate: true)
        @keypair_path = keypair_path
        @public_key = nil
        @private_key = nil
        
        if keypair_path && File.exist?(keypair_path)
          load_keypair(keypair_path)
        elsif auto_generate
          generate_keypair
        end
      end

      # Generate a new RSA keypair
      def generate_keypair(bits: DEFAULT_RSA_BITS)
        rsa = OpenSSL::PKey::RSA.new(bits)
        @private_key = rsa
        @public_key = rsa.public_key
        
        {
          public_key: export_public_key,
          private_key_fingerprint: key_fingerprint(@public_key)
        }
      end

      # Save keypair to file (private key is encrypted with passphrase if provided)
      def save_keypair(path, passphrase: nil)
        raise 'No keypair to save' unless @private_key

        FileUtils.mkdir_p(File.dirname(path))
        
        pem = if passphrase
                cipher = OpenSSL::Cipher.new('aes-256-cbc')
                @private_key.to_pem(cipher, passphrase)
              else
                @private_key.to_pem
              end
        
        File.write(path, pem, mode: 'wb')
        File.chmod(0o600, path)  # Restrict permissions
        
        # Also save public key separately for easy sharing
        pub_path = "#{path}.pub"
        File.write(pub_path, export_public_key, mode: 'wb')
        
        { private_key_path: path, public_key_path: pub_path }
      end

      # Load keypair from file
      def load_keypair(path, passphrase: nil)
        pem = File.read(path)
        @private_key = OpenSSL::PKey::RSA.new(pem, passphrase)
        @public_key = @private_key.public_key
        
        { fingerprint: key_fingerprint(@public_key) }
      rescue OpenSSL::PKey::RSAError => e
        raise "Failed to load keypair: #{e.message}"
      end

      # Export public key as PEM string (for sharing with others)
      def export_public_key
        raise 'No public key available' unless @public_key
        @public_key.to_pem
      end

      # Import a public key from PEM string
      def import_public_key(pem_string)
        OpenSSL::PKey::RSA.new(pem_string)
      rescue OpenSSL::PKey::RSAError => e
        raise "Invalid public key: #{e.message}"
      end

      # Encrypt a message for a recipient (using their public key)
      # Returns a hash with encrypted_blob and blob_hash
      def encrypt(plaintext, recipient_public_key)
        recipient_key = if recipient_public_key.is_a?(String)
                          import_public_key(recipient_public_key)
                        else
                          recipient_public_key
                        end

        # Hybrid encryption:
        # 1. Generate a random AES key
        # 2. Encrypt the message with AES
        # 3. Encrypt the AES key with RSA
        
        aes_key = OpenSSL::Random.random_bytes(AES_KEY_BITS / 8)
        iv = OpenSSL::Random.random_bytes(12)  # GCM uses 12-byte IV
        
        cipher = OpenSSL::Cipher.new(AES_CIPHER)
        cipher.encrypt
        cipher.key = aes_key
        cipher.iv = iv
        
        # Encrypt the plaintext
        plaintext_bytes = plaintext.is_a?(String) ? plaintext : plaintext.to_json
        ciphertext = cipher.update(plaintext_bytes) + cipher.final
        auth_tag = cipher.auth_tag
        
        # Encrypt the AES key with RSA
        encrypted_key = recipient_key.public_encrypt(aes_key, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING)
        
        # Package everything together
        envelope = {
          version: 1,
          algorithm: 'RSA-2048+AES-256-GCM',
          encrypted_key: Base64.strict_encode64(encrypted_key),
          iv: Base64.strict_encode64(iv),
          auth_tag: Base64.strict_encode64(auth_tag),
          ciphertext: Base64.strict_encode64(ciphertext)
        }
        
        encrypted_blob = Base64.strict_encode64(envelope.to_json)
        blob_hash = "sha256:#{Digest::SHA256.hexdigest(encrypted_blob)}"
        
        {
          encrypted_blob: encrypted_blob,
          blob_hash: blob_hash,
          size_bytes: encrypted_blob.bytesize
        }
      end

      # Decrypt a message using our private key
      def decrypt(encrypted_blob)
        raise 'No private key available for decryption' unless @private_key

        # Decode the envelope
        envelope_json = Base64.strict_decode64(encrypted_blob)
        envelope = JSON.parse(envelope_json, symbolize_names: true)
        
        # Verify version
        unless envelope[:version] == 1
          raise "Unsupported encryption version: #{envelope[:version]}"
        end
        
        # Decrypt the AES key with RSA
        encrypted_key = Base64.strict_decode64(envelope[:encrypted_key])
        aes_key = @private_key.private_decrypt(encrypted_key, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING)
        
        # Decrypt the ciphertext with AES
        cipher = OpenSSL::Cipher.new(AES_CIPHER)
        cipher.decrypt
        cipher.key = aes_key
        cipher.iv = Base64.strict_decode64(envelope[:iv])
        cipher.auth_tag = Base64.strict_decode64(envelope[:auth_tag])
        
        ciphertext = Base64.strict_decode64(envelope[:ciphertext])
        plaintext = cipher.update(ciphertext) + cipher.final
        
        # Try to parse as JSON, otherwise return as string
        begin
          JSON.parse(plaintext, symbolize_names: true)
        rescue JSON::ParserError
          plaintext
        end
      end

      # Compute hash of encrypted blob (for audit logging)
      def self.hash_blob(encrypted_blob)
        "sha256:#{Digest::SHA256.hexdigest(encrypted_blob)}"
      end

      # Verify blob hash
      def self.verify_hash(encrypted_blob, expected_hash)
        actual_hash = hash_blob(encrypted_blob)
        actual_hash == expected_hash
      end

      # Get fingerprint of a public key (for identification)
      def key_fingerprint(key = nil)
        key ||= @public_key
        return nil unless key
        
        der = key.to_der
        hash = Digest::SHA256.hexdigest(der)
        # Format as colon-separated pairs for readability
        hash.scan(/../).join(':')[0, 47]
      end

      # Check if this crypto instance has a complete keypair
      def has_keypair?
        !@private_key.nil? && !@public_key.nil?
      end

      # Check if this crypto instance can only encrypt (no private key)
      def encrypt_only?
        @private_key.nil? && !@public_key.nil?
      end

      # Create a crypto instance for encryption only (with someone's public key)
      def self.for_encryption(public_key_pem)
        crypto = new(auto_generate: false)
        crypto.instance_variable_set(:@public_key, crypto.import_public_key(public_key_pem))
        crypto
      end

      # Sign data with private key (for authenticity verification)
      def sign(data)
        raise 'No private key available for signing' unless @private_key
        
        data_bytes = data.is_a?(String) ? data : data.to_json
        signature = @private_key.sign(OpenSSL::Digest.new('SHA256'), data_bytes)
        Base64.strict_encode64(signature)
      end

      # Verify signature with public key
      def verify_signature(data, signature, signer_public_key = nil)
        key = if signer_public_key
                signer_public_key.is_a?(String) ? import_public_key(signer_public_key) : signer_public_key
              else
                @public_key
              end
        
        raise 'No public key available for verification' unless key
        
        data_bytes = data.is_a?(String) ? data : data.to_json
        signature_bytes = Base64.strict_decode64(signature)
        key.verify(OpenSSL::Digest.new('SHA256'), signature_bytes, data_bytes)
      end
    end
  end
end
