Pod::Spec.new do |s|
  s.name             = 'local_models_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Flutter wrapper for local model runtimes with a macOS-native FFI bridge.'
  s.description      = <<-DESC
Flutter wrapper for local model runtimes with a macOS-native FFI bridge.
                       DESC
  s.homepage         = 'https://github.com/IstiN/flutter_local_models'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'IstiN' => 'opensource@istin.dev' }

  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '14.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
