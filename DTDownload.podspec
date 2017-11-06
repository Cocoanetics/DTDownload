Pod::Spec.new do |spec|
  spec.name         = 'DTDownload'
  spec.version      = '1.1.3'
  spec.summary      = "File Downloading, Caching and Queueing."
  spec.homepage     = "https://github.com/Cocoanetics/DTDownload"
  spec.author       = { "Oliver Drobnik" => "oliver@drobnik.com" }
  spec.source       = { :git => "https://github.com/Cocoanetics/DTDownload.git", :tag => spec.version.to_s  }
  spec.ios.deployment_target = '5.0'
  spec.osx.deployment_target = '10.9'
  spec.license      = 'BSD'
  spec.requires_arc = true

  spec.subspec 'Core' do |ss|
    ss.source_files = 'Core/Source/*.{h,m}'
  	ss.dependency 'DTFoundation/Core'
  end

  spec.subspec 'Cache' do |ss|
    ss.source_files = 'Core/Source/Cache/*.{h,m}'
  	ss.frameworks = ['CoreData']
  	ss.dependency 'DTFoundation/Core'
  	ss.dependency 'DTFoundation/DTAsyncFileDeleter'
  	ss.dependency 'DTDownload/Core'
  end

  spec.subspec 'Queue' do |ss|
    ss.source_files = 'Core/Source/Queue/*.{h,m}'
  	ss.dependency 'DTDownload/Core'
  end

end
