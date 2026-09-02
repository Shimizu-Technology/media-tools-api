#!/usr/bin/env ruby

require "json"
require "minitest/autorun"
require "tempfile"
require_relative "validate-ios-native-auth-release"

class IOSNativeAuthReleaseTest < Minitest::Test
  CLERK_FRONTEND_API = "https://welcomed-earwig-86.clerk.accounts.dev"
  APPLE_TEAM_ID = "4T358A5S74"
  BUNDLE_ID = "com.ShimizuTechnology.MediaTools"

  def test_accepts_checked_in_release_attestation
    assert validate!(File.expand_path("../ios/app-store/native-auth-release.json", __dir__))
  end

  def test_rejects_missing_or_wrong_confirmation_source
    missing = valid_attestation.tap { |value| value.delete("confirmationSource") }
    wrong = valid_attestation.merge("confirmationSource" => "not verified")

    assert_raises(RuntimeError) { validate_temp!(missing) }
    assert_raises(RuntimeError) { validate_temp!(wrong) }
  end

  def test_rejects_missing_or_malformed_confirmation_date
    missing = valid_attestation.tap { |value| value.delete("confirmedOn") }
    malformed = valid_attestation.merge("confirmedOn" => "September 2, 2026")
    impossible = valid_attestation.merge("confirmedOn" => "2026-02-30")

    assert_raises(RuntimeError) { validate_temp!(missing) }
    assert_raises(RuntimeError) { validate_temp!(malformed) }
    assert_raises(RuntimeError) { validate_temp!(impossible) }
  end

  private

  def valid_attestation
    {
      "clerkFrontendAPI" => CLERK_FRONTEND_API,
      "appleTeamID" => APPLE_TEAM_ID,
      "bundleID" => BUNDLE_ID,
      "appleNativeMappingConfirmed" => true,
      "confirmedOn" => "2026-09-02",
      "confirmationSource" => IOSNativeAuthRelease::CONFIRMATION_SOURCE,
    }
  end

  def validate_temp!(attestation)
    Tempfile.create(["native-auth-release", ".json"]) do |file|
      file.write(JSON.generate(attestation))
      file.flush
      validate!(file.path)
    end
  end

  def validate!(path)
    IOSNativeAuthRelease.validate!(
      path: path,
      clerk_frontend_api: CLERK_FRONTEND_API,
      apple_team_id: APPLE_TEAM_ID,
      bundle_id: BUNDLE_ID
    )
  end
end
