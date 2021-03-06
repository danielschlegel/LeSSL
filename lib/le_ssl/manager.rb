module LeSSL
  class Manager
    PRODUCTION_ENDPOINT = 'https://acme-v01.api.letsencrypt.org/'
    DEVELOPMENT_ENDPOINT = 'https://acme-staging.api.letsencrypt.org/'

    def initialize(options={})
      email = options[:email] || email_from_env
      if options[:endpoint]
        @endpoint = options[:endpoint].to_s != 'production' ? DEVELOPMENT_ENDPOINT : PRODUCTION_ENDPOINT
      else
        @endpoint = Rails.env.development? ? DEVELOPMENT_ENDPOINT : PRODUCTION_ENDPOINT
      end

      raise LeSSL::NoContactEmailError if email.nil?
      raise LeSSL::TermsNotAcceptedError unless options[:agree_terms] == true

      self.private_key = options[:private_key] ? options[:private_key] : nil

      private_key      # Check private key

      register(email) unless options[:skip_register] == true
    end

    # Authorize the client
    # for a domain name.
    #
    # Challenge options:
    #  - HTTP (default and recommended)
    #  - DNS
    def authorize_for_domain(domain, options={})
      authorization = client.authorize(domain: domain)
      web_root = options[:web_root] || Rails.root.join('public')

      # Default challenge is via HTTP
      # but the developer can also use
      # a DNS TXT record to authorize.
      if options[:challenge] == :dns
        challenge = authorization.dns01

        unless options[:skip_puts]
          puts "===================================================================="
          puts "Record:"
          puts
          puts " - Name: #{challenge.record_name}.#{domain}"
          puts " - Type: #{challenge.record_type}"
          puts " - Value: #{challenge.record_content}"
          puts
          puts "Create the record; Wait a minute (or two); Request for verification!"
          puts "===================================================================="
        end

        # With this option the dns verification is
        # done automatically. LeSSL waits until a
        # valid record on your DNS servers was found
        # and requests a verification.
        #
        # CAUTION! This is a blocking the thread!
        if options[:automatic_verification]
          dns = begin
            if ns = options[:custom_nameservers]
              LeSSL::DNS.new(ns)
            else
              LeSSL::DNS.new
            end
          end

          puts
          puts 'Wait until the TXT record was set...'

          # Wait with verification until the
          # challenge record is valid.
          while dns.challenge_record_invalid?(domain, challenge.record_content)
            puts 'DNS record not valid' if options[:verbose]

            sleep(2) # Wait 2 seconds
          end

          puts 'Valid TXT record found. Continue with verification...'

          return request_verification(challenge)
        else
          return challenge
        end
      else
        challenge = authorization.http01

        file_name = File.join(web_root, challenge.filename)
        dir = File.dirname(File.join(web_root, challenge.filename))

        FileUtils.mkdir_p(dir)

        File.write(file_name, challenge.file_content)
        
        return challenge.verify_status
      end
    end

    def request_verification(challenge)
      challenge.request_verification
      sleep(1)
      return challenge.verify_status
    end

    def request_certificate(*domains, ssl_path: Rails.root.join('config', 'ssl'))
      csr = Acme::Client::CertificateRequest.new(names: domains)
      certificate = client.new_certificate(csr)

      FileUtils.mkdir_p(ssl_path)

      File.write(File.join(ssl_path, 'privkey.pem'), certificate.request.private_key.to_pem)
      File.write(File.join(ssl_path, 'cert.pem'), certificate.to_pem)
      File.write(File.join(ssl_path, 'chain.pem'), certificate.chain_to_pem)
      File.write(File.join(ssl_path, 'fullchain.pem'), certificate.fullchain_to_pem)

      return certificate
    rescue Acme::Client::Error::Unauthorized => e
      raise LeSSL::UnauthorizedError, e.message
    end

    def register(email)
      client.register(contact: "mailto:#{email}").agree_terms
      return true
    rescue Acme::Client::Error::Malformed => e
      return false if e.message == "Registration key is already in use"
      raise e
    end

    private

    def private_key=(key)
      @private_key = begin
        if key.is_a?(OpenSSL::PKey::RSA)
          key
        elsif key.is_a?(String)
          OpenSSL::PKey::RSA.new(key)
        elsif key.nil?
          nil
        else
          raise LeSSL::PrivateKeyInvalidFormat
        end
      end
    end

    def private_key
      self.private_key = private_key_string_from_env if @private_key.nil?
      raise(LeSSL::NoPrivateKeyError, "No private key for certificate account found") if @private_key.nil?
      
      @private_key
    end

    def client
      @acme_client ||= Acme::Client.new(private_key: private_key, endpoint: @endpoint)
    end

    def private_key_string_from_env
      warn "DEPRECATION WARNING! Use LESSL_CLIENT_PRIVATE_KEY instead of CERT_ACCOUNT_PRIVATE_KEY for environment variable!" if ENV['CERT_ACCOUNT_PRIVATE_KEY'].present?
      return ENV['LESSL_CLIENT_PRIVATE_KEY'] || ENV['CERT_ACCOUNT_PRIVATE_KEY'].presence
    end

    def email_from_env
      warn "DEPRECATION WARNING! Use LESSL_CONTACT_EMAIL instead of CERT_ACCOUNT_EMAIL for environment variable!" if ENV['CERT_ACCOUNT_EMAIL'].present?
      return ENV['LESSL_CONTACT_EMAIL'].presence || ENV['CERT_ACCOUNT_EMAIL'].presence
    end
  end
end