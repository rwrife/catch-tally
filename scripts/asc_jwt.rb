#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'
require 'optparse'

options = {
  ttl_seconds: 1_200,
}

OptionParser.new do |opts|
  opts.banner = 'Usage: asc_jwt.rb --key-id KEY --issuer-id ISSUER --key-path AuthKey.p8 [--ttl-seconds 1200]'
  opts.on('--key-id VALUE', String) { |v| options[:key_id] = v }
  opts.on('--issuer-id VALUE', String) { |v| options[:issuer_id] = v }
  opts.on('--key-path VALUE', String) { |v| options[:key_path] = v }
  opts.on('--ttl-seconds VALUE', Integer) { |v| options[:ttl_seconds] = v }
end.parse!

%I[key_id issuer_id key_path].each do |required|
  abort("missing --#{required.to_s.tr('_', '-')}") if options[required].to_s.empty?
end

key_pem = File.read(options[:key_path], encoding: 'utf-8')
private_key = OpenSSL::PKey.read(key_pem)

header = {
  alg: 'ES256',
  kid: options[:key_id],
  typ: 'JWT',
}
payload = {
  iss: options[:issuer_id],
  aud: 'appstoreconnect-v1',
  exp: Time.now.to_i + options[:ttl_seconds],
}

def b64url(data)
  Base64.urlsafe_encode64(data, padding: false)
end

signing_input = "#{b64url(header.to_json)}.#{b64url(payload.to_json)}"
der_signature = private_key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(signing_input))

asn1 = OpenSSL::ASN1.decode(der_signature)
r = asn1.value[0].value.to_i
s = asn1.value[1].value.to_i
raw_signature = [r.to_s(16).rjust(64, '0') + s.to_s(16).rjust(64, '0')].pack('H*')

puts "#{signing_input}.#{b64url(raw_signature)}"
