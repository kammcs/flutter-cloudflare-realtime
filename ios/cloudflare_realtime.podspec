#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint cloudflare_realtime.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'cloudflare_realtime'
  s.version          = '0.0.1'
  s.summary          = 'Call audio routing for cloudflare_realtime.'
  s.description      = <<-DESC
Native call audio routing (speaker, receiver, headsets) for the cloudflare_realtime Flutter package.
                       DESC
  s.homepage         = 'https://github.com/kammcs/flutter-cloudflare-realtime'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'kammcs' => '85201048+kammcs@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files = 'cloudflare_realtime/Sources/cloudflare_realtime/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # The privacy manifest (the plugin reads UserDefaults, a required reason
  # API). Package.swift ships the same file as a resource.
  s.resource_bundles = {'cloudflare_realtime_privacy' => ['cloudflare_realtime/Sources/cloudflare_realtime/PrivacyInfo.xcprivacy']}
end
