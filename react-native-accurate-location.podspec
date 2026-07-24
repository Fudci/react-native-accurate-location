require "json"
package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-accurate-location"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/local"
  s.license      = "MIT"
  s.authors      = { "myworkspace" => "dev@myworkspace.com" }
  s.platforms    = { :ios => "13.4" }
  s.source       = { :path => "." }
  s.source_files = "ios/**/*.{h,m,mm}"
  s.dependency "React-Core"

  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  else
    s.dependency "React-callinvoker"
  end
end
