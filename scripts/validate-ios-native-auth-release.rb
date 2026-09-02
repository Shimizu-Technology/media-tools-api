#!/usr/bin/env ruby

require "date"
require "json"

module IOSNativeAuthRelease
  CONFIRMATION_SOURCE = "Clerk Dashboard > Configure > Native applications"

  def self.validate!(path:, clerk_frontend_api:, apple_team_id:, bundle_id:)
    attestation = JSON.parse(File.read(path, encoding: "UTF-8"))

    raise "Clerk native-app mapping is not confirmed for this release" unless attestation["appleNativeMappingConfirmed"] == true
    raise "Native-auth attestation has the wrong Clerk tenant" unless attestation["clerkFrontendAPI"] == clerk_frontend_api
    raise "Native-auth attestation has the wrong Apple team" unless attestation["appleTeamID"] == apple_team_id
    raise "Native-auth attestation has the wrong bundle ID" unless attestation["bundleID"] == bundle_id
    unless attestation["confirmationSource"] == CONFIRMATION_SOURCE
      raise "Native-auth attestation was not confirmed at #{CONFIRMATION_SOURCE}"
    end

    # `confirmedOn` is intentionally an ISO 8601 calendar date, not an event timestamp.
    confirmed_on = attestation.fetch("confirmedOn")
    raise "Native-auth confirmedOn must use YYYY-MM-DD" unless confirmed_on.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    Date.iso8601(confirmed_on)
    true
  rescue KeyError
    raise "Native-auth attestation is missing confirmedOn"
  rescue ArgumentError
    raise "Native-auth confirmedOn is not a valid calendar date"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    IOSNativeAuthRelease.validate!(
      path: ARGV.fetch(0),
      clerk_frontend_api: ENV.fetch("CLERK_FRONTEND_API"),
      apple_team_id: ENV.fetch("APPLE_TEAM_ID"),
      bundle_id: ENV.fetch("APP_BUNDLE_ID")
    )
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
