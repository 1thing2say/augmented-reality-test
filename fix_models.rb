require 'xcodeproj'

project_path = "augmented reality test.xcodeproj"
project = Xcodeproj::Project.open(project_path)
target = project.targets.first

# Add Models as a folder reference
group = project.main_group.find_subpath("augmented reality test", false)

# Remove existing reference if any
existing = group.children.find { |c| c.name == "Models" }
existing.remove_from_project if existing

# Create folder reference
models_ref = group.new_reference("Models")
models_ref.last_known_file_type = "folder"

# Add to copy resources build phase
resources_phase = target.resources_build_phase
resources_phase.add_file_reference(models_ref)

project.save
