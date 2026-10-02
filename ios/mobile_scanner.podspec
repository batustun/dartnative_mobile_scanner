Pod::Spec.new do |s|
  s.name             = 'mobile_scanner'
  s.version          = '0.1.0'
  s.summary          = 'Native barcode and QR scanning for DartNative.'
  s.description      = <<-DESC
Real-time barcode and QR scanning backed by AVFoundation. An AVCaptureSession
with AVCaptureMetadataOutput does the recognizing, so camera frames never cross
into Dart.
                       DESC
  s.homepage         = 'https://github.com/batustun/dartnative_mobile_scanner'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Batuhan Ustun' => 'batustun@gmail.com' }
  s.source           = { :path => '.' }

  s.source_files     = 'Classes/**/*.swift'
  s.swift_version    = '5.9'

  # 15.0 is the minimum the tool declares for every DartNative app. Codabar needs
  # iOS 15.4 at runtime and is reported as unsupported below that, rather than
  # raising the whole plugin's floor for one symbology.
  s.platform         = :ios, '15.0'

  s.frameworks       = 'AVFoundation', 'UIKit', 'CoreMedia'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end
