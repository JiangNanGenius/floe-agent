#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "openssl"
require "uri"

API_ROOT = "https://api.appstoreconnect.apple.com/v1"

def required_env(name)
  value = ENV[name]
  abort("Missing required environment variable: #{name}") if value.nil? || value.empty?
  value
end

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def jwt_token
  key_id = required_env("ASC_KEY_ID")
  issuer_id = required_env("ASC_ISSUER_ID")
  key = OpenSSL::PKey::EC.new(File.read(required_env("ASC_API_KEY_PATH")))
  now = Time.now.to_i
  header = base64url(JSON.generate(alg: "ES256", kid: key_id, typ: "JWT"))
  payload = base64url(JSON.generate(iss: issuer_id, iat: now - 5, exp: now + 600, aud: "appstoreconnect-v1"))
  signing_input = "#{header}.#{payload}"
  digest = OpenSSL::Digest::SHA256.digest(signing_input)
  sequence = OpenSSL::ASN1.decode(key.dsa_sign_asn1(digest))
  raw_signature = sequence.value.map { |integer| [integer.value.to_i.to_s(16).rjust(64, "0")].pack("H*") }.join
  "#{signing_input}.#{base64url(raw_signature)}"
end

def request(method, path, token, query: nil, body: nil, expected: [200])
  uri = URI("#{API_ROOT}#{path}")
  uri.query = URI.encode_www_form(query) if query
  request_class = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method)
  http_request = request_class.new(uri)
  http_request["Authorization"] = "Bearer #{token}"
  http_request["Content-Type"] = "application/json"
  http_request.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(http_request) }
  unless expected.include?(response.code.to_i)
    details = begin
      JSON.parse(response.body).fetch("errors", []).map { |error| error.slice("status", "code", "title", "detail") }
    rescue JSON::ParserError
      response.body.to_s.byteslice(0, 2_000)
    end
    abort("App Store Connect API #{method.to_s.upcase} #{path} failed (HTTP #{response.code}): #{details}")
  end
  response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
end

def distribution_certificate_id(token)
  # The signing identity is imported by macOS Security.framework before this
  # script runs. Match its SHA-256 fingerprint instead of parsing the original
  # PKCS#12 here: older Apple-exported P12 files may use legacy RC2 encryption
  # that OpenSSL 3 intentionally does not load in its default provider.
  expected_fingerprint = required_env("ASC_DISTRIBUTION_CERTIFICATE_SHA256").downcase.delete(":")
  abort("ASC_DISTRIBUTION_CERTIFICATE_SHA256 must contain 64 hexadecimal characters") unless expected_fingerprint.match?(/\A[0-9a-f]{64}\z/)
  response = request(
    :get,
    "/certificates",
    token,
    query: {
      "filter[certificateType]" => "DISTRIBUTION,IOS_DISTRIBUTION",
      "fields[certificates]" => "certificateType,certificateContent,expirationDate,activated",
      "limit" => "200"
    }
  )
  certificate = response.fetch("data").find do |entry|
    content = entry.dig("attributes", "certificateContent")
    next false unless content
    Digest::SHA256.hexdigest(OpenSSL::X509::Certificate.new(Base64.decode64(content)).to_der) == expected_fingerprint
  end
  abort("The imported Apple Distribution certificate was not found in the App Store Connect team") unless certificate
  certificate.fetch("id")
end

def bundle_id_resource(token, identifier)
  response = request(
    :get,
    "/bundleIds",
    token,
    query: { "filter[identifier]" => identifier, "fields[bundleIds]" => "identifier,name,platform", "limit" => "10" }
  )
  matches = response.fetch("data").select { |entry| entry.dig("attributes", "identifier") == identifier }
  abort("Expected exactly one registered bundle ID for #{identifier}, found #{matches.count}") unless matches.one?
  matches.first.fetch("id")
end

def create_profiles(arguments)
  abort("Usage: asc_ci_profiles.rb create BUNDLE_ID OUTPUT_PATH [BUNDLE_ID OUTPUT_PATH ...]") if arguments.empty? || arguments.length.odd?
  token = jwt_token
  certificate_id = distribution_certificate_id(token)
  prefix = required_env("ASC_PROFILE_NAME_PREFIX")
  ids_path = required_env("ASC_PROFILE_IDS_FILE")
  created_ids = []

  arguments.each_slice(2).with_index do |(bundle_identifier, output_path), index|
    bundle_id = bundle_id_resource(token, bundle_identifier)
    name = "#{prefix} #{index + 1} #{bundle_identifier}"
    payload = {
      data: {
        type: "profiles",
        attributes: { name: name, profileType: "IOS_APP_STORE" },
        relationships: {
          bundleId: { data: { type: "bundleIds", id: bundle_id } },
          certificates: { data: [{ type: "certificates", id: certificate_id }] }
        }
      }
    }
    response = request(:post, "/profiles", token, body: payload, expected: [201])
    profile = response.fetch("data")
    content = profile.dig("attributes", "profileContent")
    abort("Created profile #{name} did not include profileContent") unless content
    File.binwrite(output_path, Base64.decode64(content))
    created_ids << profile.fetch("id")
    File.write(ids_path, created_ids.join("\n") + "\n")
    puts "Created temporary App Store profile #{name}"
  end
end

def delete_profiles
  ids_path = required_env("ASC_PROFILE_IDS_FILE")
  exit 0 unless File.exist?(ids_path)
  token = jwt_token
  File.readlines(ids_path, chomp: true).reject(&:empty?).each do |profile_id|
    request(:delete, "/profiles/#{profile_id}", token, expected: [204])
    puts "Deleted temporary App Store profile #{profile_id}"
  end
end

command = ARGV.shift
case command
when "create"
  create_profiles(ARGV)
when "delete"
  delete_profiles
else
  abort("Expected create or delete")
end
