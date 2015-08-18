Pod::Spec.new do |s|
  s.name         = "ISpdy"
  s.version      = "0.1.0"
  s.summary      = "Spdy client for macosx and iphoneos."

  s.homepage     = "https://github.com/Voxer/ispdy"


  s.license      = { :type => 'MIT', :file => 'LICENSE' }


  s.author       = { "Fedor Indutny" => "fedor.indutny@gmail.com" }

  s.ios.deployment_target = '5.0'
  s.osx.deployment_target = '10.7'

  s.source       = { :git => "https://github.com/Voxer/ispdy.git", :tag => "v#{s.version.to_s}" }

  s.source_files  = 'src', 'src/*.{h,m}', 'include/*.h'

  s.public_header_files = 'include/*.h'



  s.frameworks = 'Security'

  s.library   = 'z'

  s.requires_arc = true

end
