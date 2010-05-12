#!/usr/bin/env ruby
# encoding: UTF-8


# Fortran Structure extractor ;)
#

require 'optparse'
require 'erb'
require 'uv'

$project_title = 'Unnamed'
FOOTER = %q{<p><em>Analysis by struct.rb - David Siñuela Pastor</em></p>}

class StructureExtractor
  attr_accessor :all_methods, :all_function_names, :files_info, :files

  def initialize(path)
    @dir = path
    Dir.chdir(@dir)

    pattern = File.join(@dir, '**', '*.f')
    @files = Dir.glob(pattern)

    @files_info = @files.map do |filename|
      puts "Searching for declarations in #{filename}..."
      FortranFile.new(filename)
    end

    @all_methods = @files_info.map { |fi| fi.methods }.flatten.uniq {|a,b| a.name <=> b.name }.sort {|a,b| a.name <=> b.name }
    @all_function_names = @all_methods.collect { |m| m.name.scan(/^function:(\w*)/i) }.flatten.sort.uniq
    @files_info.each do |f|
      puts "File #{f.filename}..."
      f.methods.each do |m|
        puts "Generating call tree for #{m.name}..."
        m.update_calls(@all_function_names, @all_methods)
      end
    end

  end

  def print_results
    @files_info.each do |f|
      puts "# #{f.filename}"
      f.methods.each do |m|
        puts m
        puts m.calls
      end
    end
  end
end

class String
  def to_html_page
    self.gsub(/:/, '_') << '.html'
  end
end

class StructureExtractorHtmlOutput
  THEME = 'dawn'
  def self.write_output(structure, output_path)
    s = structure
    Dir.mkdir(output_path)
    Dir.chdir(output_path)
    Uv.copy_files "xhtml", "."
    write_index_to_file(structure)

    s.all_methods.each do |m|
      write_method_to_file(m, m.name.to_html_page)
    end
  end

  def self.write_index_to_file(structure)
    filename = "index.html"
    methods = structure.all_methods.clone
    template = %q{
      <!DOCTYPE html>
      <html>
      <head>
              <meta charset="utf-8">
              <title><%= $project_title %></title>
              <link rel="stylesheet" href="css/<%= THEME %>.css" type="text/css" media="screen" />
      </head>
      <body>
      <h1><%= $project_title %></h1>

      <h2>Call tree</h2>
      <ul>
      <% while cmethod = methods.shift do %>
        <% if cmethod.respond_to?(:any?) %>
          <% if cmethod.any? %>
            <ul>
              <% cmethod.each do |m| %>
                <li><a href="<%= m.name.to_html_page %>"><%= m.name %></a></li>
              <% end %>
            </ul>
          <% end %>
          </li>
        <% else %>
          <li><a href="<%= cmethod.name.to_html_page %>"><%= cmethod.name %></a>
          <% methods.unshift(cmethod.calls) %>
        <% end %>
      <% end %>
      </ul>
      <%= FOOTER %>

      </body>
      </html>
    }

    puts "Writing file #{filename}"

    output = ERB.new(template).result(binding)
    self.write_to_file(filename, output)
  end

  def self.highlight(text)
    result = Uv.parse( text, "xhtml", "fortran", true, "dawn")
  end

  def self.write_method_to_file(m, filename)
    filename = m.name.to_html_page
    template = %q{
      <!DOCTYPE html>
      <html>
      <head>
              <meta charset="utf-8">
              <title><%= m.name %></title>
              <link rel="stylesheet" href="css/<%= THEME %>.css" type="text/css" media="screen" />
      </head>
      <body>
      <h1><%= m.name %></h1>
      <div class="method-info">File: <%= m.file.filename %></div>

      <h2>All calls</h2>
      <ul>
        <% m.calls.each do |c| %>
          <li><a href="<%= c.name.to_html_page %>"><%= c.name %></a></li>
        <% end %>
      </ul>

      <h2>Source code</h2>
      <code>
      <pre>
<%= highlight(m.source) %>
      </pre>
      </code>
      <%= FOOTER %>
      </body>
      </html>
    }

    puts "Writing file #{filename}"

    output = ERB.new(template).result(binding)
    self.write_to_file(filename, output)
  end
private
  def self.write_to_file(filename, contents)
    file = File.open(filename, 'w+')
    file.write contents
    file.close
  end
end

class FortranFile

  attr_accessor :filename
  attr_accessor :methods

  def initialize(filename)
    @filename = filename
    @methods = extract_methods(filename)
  end

  def get_source_interval(interval)
    File.open(@filename).entries.slice(interval).join
  end

private
  def extract_methods(filename)
    file = File.open(filename)

    last_line = 0
    methods = file.lines.map do |line|
      last_line += 1
      m =line.scan(/^[^!*c]\s*(?:\w+\s+)*(function|subroutine)[ \t]+(\w+).*$/i).map do |e| 
        MethodDefinition.new(e.join(':'), self, $., $.+1)
      end
      m.each { |m| puts "Found #{m.name}" }
      m
    end
    file.close

    methods.flatten!
    methods.reverse_each do |m|
      m.end_line = last_line - 1
      last_line = m.start_line
    end

    return methods
  end

end

class MethodDefinition
  attr_accessor :name, :file, :start_line, :end_line, :calls
  attr_accessor :lines

  def initialize(name, file, start_line, end_line)
    @name = name.downcase
    @file = file
    @start_line = start_line
    @end_line = end_line
    @calls = nil
    update_lines()
  end

  def update_calls(function_list, all_methods)
    @calls = []
    @calls += extract_subroutine_calls(all_methods)
    @calls += extract_function_calls(function_list, all_methods)
    @calls.sort { |a,b| a.name <=> b.name }
    @calls.delete(self)
    @calls.uniq
  end

  def start_line=(a)
    @start_line = a
    update_lines()
  end

  def end_line=(a)
    @end_line = a
    update_lines()
  end

  def extract_subroutine_calls(all_methods)
    call_lines = File.open(file.filename).entries[start_line..end_line-1].map do |line|
      line.scan(/^[^*c]\s*call[ \t]+(\w+)/i).flatten.uniq.collect(&:downcase)
    end.compact.flatten.uniq.sort
    call_lines.map{ |c| all_methods.find { |m| m.name == "subroutine:#{c}" } }.compact
  end

  def extract_function_calls(function_list, all_methods)
    call_lines = File.open(file.filename).entries[start_line..end_line-1].map do |line|
      line.scan(/^[^*c]\s*.*(#{function_list.join("|")})/i).flatten.uniq.collect(&:downcase)
    end.compact.flatten.uniq.sort
    call_lines.map{|c| all_methods.find { |m| m.name == "function:#{c}" } }.compact
  end

  def to_s
    @name + " [#{@start_line},#{@end_line}]"
  end

  def source
    @file.get_source_interval((@start_line-1)..(@end_line-1))
  end

private

  def update_lines
    @lines = end_line - start_line
  end


end

opts = OptionParser.new(ARGV) do |o|
  o.banner = 'Usage: struct.rb [options] source_directory'
  o.on('-d DIRECTORY', '--directory', 'Output directory') { |d| $directory = d}
  o.on('-t TITLE', '--title', 'Project title') { |t| $project_title = t}
  o.on('-h') { puts o; exit }
  o.parse!
end
path = File.join(File.expand_path('.'), $directory)

s = StructureExtractor.new(File.expand_path(ARGV.last))
StructureExtractorHtmlOutput::write_output(s, path)
