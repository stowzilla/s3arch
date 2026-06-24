# frozen_string_literal: true

# Load s3arch Rake tasks into the consuming application.
#
# Usage (in your Rakefile):
#   require 's3arch/tasks'
#
# Or let your framework (e.g., belt) auto-require this.

Dir.glob(File.join(__dir__, '../../tasks/**/*.rake')).each { |r| load r }
