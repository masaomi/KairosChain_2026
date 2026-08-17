#!/usr/bin/env ruby
# frozen_string_literal: true

# render_dashboard.rb — Multi-LLM Review Dashboard renderer
#
# Protocol:
#   stdin:  JSON review data
#   stdout: self-contained HTML with embedded data
#   stderr: error messages
#   exit 0: success, non-0: failure

require 'json'

data = $stdin.read
begin
  parsed = JSON.parse(data)
rescue JSON::ParserError => e
  $stderr.puts "Invalid JSON: #{e.message}"
  exit 1
end

template_path = File.join(__dir__, '..', 'assets', 'review_dashboard.html')
unless File.exist?(template_path)
  $stderr.puts "Template not found: #{template_path}"
  exit 1
end

template = File.read(template_path)

# Replace the SAMPLE constant with actual data and auto-load on page open
json_literal = JSON.generate(parsed)

# Replace the SAMPLE object with actual data
html = template.sub(
  /const SAMPLE = \{.+?\n\};/m,
  "const SAMPLE = #{JSON.pretty_generate(parsed)};"
)

# Add auto-load: call loadSample() on DOMContentLoaded
unless html.include?('auto-loaded')
  html = html.sub(
    '</script>',
    "\n// auto-loaded by render_dashboard.rb\n" \
    "document.addEventListener('DOMContentLoaded', loadSample);\n" \
    '</script>'
  )
end

# Update subtitle to show generation timestamp
html = html.sub(
  'HTML resource (assets/)',
  "Generated #{Time.now.strftime('%Y-%m-%d %H:%M')}"
)

$stdout.write(html)
