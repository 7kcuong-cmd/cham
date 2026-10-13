Pod::Spec.new do |s|
  s.name             = 'cham_recorder'
  s.version          = '0.1.0'
  s.summary          = 'Ghi màn hình trong app (ReplayKit).'
  s.homepage         = 'https://github.com/7kcuong-cmd/cham'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Cham' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
end
