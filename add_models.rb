require 'xcodeproj'

project_path = "augmented reality test.xcodeproj"
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

# The group where files will be added
group = project.main_group.find_subpath(File.join("augmented reality test", "Models"), true)

# Move files from Assets.xcassets to Models
require 'fileutils'
models_dir = File.join("augmented reality test", "Models")
FileUtils.mkdir_p(models_dir)

Dir.glob("augmented reality test/Assets.xcassets/*.{usdz,reality}").each do |file|
  basename = File.basename(file)
  dest = File.join(models_dir, basename)
  FileUtils.mv(file, dest)
  
  # Add to Xcode group
  file_ref = group.new_reference(basename)
  
  # Add to build phase
  target.resources_build_phase.add_file_reference(file_ref)
end

project.save
