# frozen_string_literal: true

require 'openssl'
require 'base64'
require 'digest'
require 'json'
require 'fileutils'

module MMP
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

    def generate_keypair(bits: DEFAULT_RSA_BITS)
      rsa = OpenSSL::PKey::RSA.new(bits)
      @private_key = rsa
      @public_key = rsa.public_key
      { public_key: export_public_key, private_key_fingerprint: key_fingerprint(@public_key) }
    end

    def save_keypair(path, passphrase: nil)
      raise 'No keypair to save' unless @private_key
      FileUtils.mkdir_p(File.dirname(path))
      pem = passphrase ? @private_key.to_pem(OpenSSL::Cipher.new('aes-256-cbc'), passphrase) : @private_key.to_pem
      File.write(path, pem, mode: 'wb')
      File.chmod(0o600, path)
      pub_path = "#{path}.pub"
      File.write(pub_path, export_public_key, mode: 'wb')
      { private_key_path: path, public_key_path: pub_path }
    end

    def load_keypair(path, passphrase: nil)
      pem = File.read(path)
      @private_key = OpenSSL::PKey::RSA.new(pem, passphrase)
      @public_key = @private_key.public_key
      { fingerprint: key_fingerprint(@public_key) }
    rescue OpenSSL::PKey::RSAError => e
      raise "Failed to load keypair: #{e.message}"
    end

    def export_public_key
      raise 'No public key available' unless @public_key
      @public_key.to_pem
    end

    def import_public_key(pem_string)
      OpenSSL::PKey::RSA.new(pem_string)
    rescue OpenSSL::PKey::RSAError => e
      raise "Invalid public key: #{e.message}"
    end

    def encrypt(plaintext, recipient_public_key)
      recipient_key = recipient_public_key.is_a?(String) ? import_public_key(recipient_public_key) : recipient_public_key
      aes_key = OpenSSL::Random.random_bytes(AES_KEY_BITS / 8)
      iv = OpenSSL::Random.random_bytes(12)
      cipher = OpenSSL::Cipher.new(AES_CIPHER)
      cipher.encrypt
      cipher.key = aes_key
      cipher.iv = iv
      plaintext_bytes = plaintext.is_a?(String) ? plaintext : plaintext.to_json
      ciphertext = cipher.update(plaintext_bytes) + cipher.final
      auth_tag = cipher.auth_tag
      encrypted_key = recipient_key.public_encrypt(aes_key, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING)
      envelope = { version: 1, algorithm: 'RSA-2048+AES-256-GCM', encrypted_key: Base64.strict_encode64(encrypted_key), iv: Base64.strict_encode64(iv), auth_tag: Base64.strict_encode64(auth_tag), ciphertext: Base64.strict_encode64(ciphertext) }
      encrypted_blob = Base64.strict_encode64(envelope.to_json)
      blob_hash = "sha256:#{Digest::SHA256.hexdigest(encrypted_blob)}"
      { encrypted_blob: encrypted_blob, blob_hash: blob_hash, size_bytes: encrypted_blob.bytesize }
    end

    def decrypt(encrypted_blob)
      raise 'No private key available for decryption' unless @private_key
      envelope_json = Base64.strict_decode64(encrypted_blob)
      envelope = JSON.parse(envelope_json, symbolize_names: true)
      raise "Unsupported encryption version: #{envelope[:version]}" unless envelope[:version] == 1
      encrypted_key = Base64.strict_decode64(envelope[:encrypted_key])
      aes_key = @private_key.private_decrypt(encrypted_key, OpenSSL::PKey::RSA::PKCS1_OAEP_PADDING)
      cipher = OpenSSL::Cipher.new(AES_CIPHER)
      cipher.decrypt
      cipher.key = aes_key
      cipher.iv = Base64.strict_decode64(envelope[:iv])
      cipher.auth_tag = Base64.strict_decode64(envelope[:auth_tag])
      ciphertext = Base64.strict_decode64(envelope[:ciphertext])
      plaintext = cipher.update(ciphertext) + cipher.final
      begin; JSON.parse(plaintext, symbolize_names: true); rescue JSON::ParserError; plaintext; end
    end

    def self.hash_blob(encrypted_blob) = "sha256:#{Digest::SHA256.hexdigest(encrypted_blob)}"
    def self.verify_hash(encrypted_blob, expected_hash) = hash_blob(encrypted_blob) == expected_hash
    def key_fingerprint(key = nil)
      key ||= @public_key
      return nil unless key
      Digest::SHA256.hexdigest(key.to_der).scan(/../).join(':')[0, 47]
    end
    def has_keypair? = !@private_key.nil? && !@public_key.nil?
    def encrypt_only? = @private_key.nil? && !@public_key.nil?

    def self.for_encryption(public_key_pem)
      crypto = new(auto_generate: false)
      crypto.instance_variable_set(:@public_key, crypto.import_public_key(public_key_pem))
      crypto
    end

    def sign(data)
      raise 'No private key available for signing' unless @private_key
      data_bytes = data.is_a?(String) ? data : data.to_json
      Base64.strict_encode64(@private_key.sign(OpenSSL::Digest.new('SHA256'), data_bytes))
    end

    def verify_signature(data, signature, signer_public_key = nil)
      key = signer_public_key ? (signer_public_key.is_a?(String) ? import_public_key(signer_public_key) : signer_public_key) : @public_key
      raise 'No public key available for verification' unless key
      data_bytes = data.is_a?(String) ? data : data.to_json
      key.verify(OpenSSL::Digest.new('SHA256'), Base64.strict_decode64(signature), data_bytes)
    end
  end
end
