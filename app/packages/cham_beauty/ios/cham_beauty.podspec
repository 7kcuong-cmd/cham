Pod::Spec.new do |s|
  s.name             = 'cham_beauty'
  s.version          = '0.1.0'
  s.summary          = 'Làm mịn da camera cuộc gọi Chạm (iOS).'
  s.description      = 'Bộ xử lý khung hình cho flutter_webrtc. CHƯA THỬ TRÊN MÁY THẬT.'
  s.homepage         = 'https://call.shoprobotai.com'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Chạm' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'flutter_webrtc'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
end
