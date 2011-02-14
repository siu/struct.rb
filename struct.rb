#!/usr/bin/env ruby
# encoding: UTF-8


# Fortran Structure extractor ;)
#

require 'rubygems'
require 'optparse'
require 'fileutils'
require 'erb'

$project_title = 'Unnamed'
STRUCT_PATH = File.expand_path(File.dirname(__FILE__))
FOOTER = %q{<p><em>Analysis by struct.rb - David Siñuela Pastor</em></p>}
TEMPLATE_DIR = File.join(STRUCT_PATH, 'templates')
CSS_DIR = File.join(STRUCT_PATH, 'css')

class StructureExtractor
  attr_accessor :all_methods, :all_function_names, :files_info, :files

  def initialize(path)
    @dir = path

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

  def to_fortran_file
    self.split(':').last << '.f'
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

    declaration = Regexp.new(/^[^!*c]\s*(?:\w+\s+)*(function|subroutine)[ \t]+(\w+).*$/i)

    last_line = 0
    methods = file.lines.map do |line|
      last_line += 1
      m =line.scan(declaration).map do |e| 
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
    sub_call = Regexp.new(/^[^*c]\s*call[ \t]+(\w+)/i)
    call_lines = File.open(file.filename).entries[start_line..end_line-1].map do |line|
      line.scan(sub_call).flatten.uniq.collect(&:downcase)
    end.compact.flatten.uniq.sort
    call_lines.map{ |c| all_methods.find { |m| m.name == "subroutine:#{c}" } }.compact
  end

  def extract_function_calls(function_list, all_methods)
    fun_call = Regexp.new(/^[^*c]\s*.*(#{function_list.join("|")})\(/i)
    call_lines = File.open(file.filename).entries[start_line..end_line-1].map do |line|
      line.scan(fun_call).flatten.uniq.collect(&:downcase)
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

class StructureExtractorHtmlOutput
  require 'uv'
  THEME = 'dawn'

  def self.write_output(structure, output_path, overwrite = false)
    s = structure
    FileUtils.rm_rf(output_path) if overwrite
    FileUtils.mkdir(output_path)
    FileUtils.cp_r(CSS_DIR, output_path)
    write_index_to_file(structure, File.join(output_path, 'index.html'))

    s.all_methods.each do |m|
      write_method_to_file(m, File.join(output_path, m.name.to_html_page))
    end
  end

  def self.write_index_to_file(structure, file_path)
    methods = structure.all_methods.clone
    template = self.read_template('index.html.erb')

    puts "Writing file #{file_path}"

    output = ERB.new(template).result(binding)
    self.write_to_file(file_path, output)
  end

  def self.highlight(text)
    result = Uv.parse( text, "xhtml", "fortran", true, "dawn")
  end

  def self.read_template(template)
    File.read(File.join(TEMPLATE_DIR, template))
  end

  def self.write_method_to_file(m, file_path)
    template = self.read_template('method.html.erb')

    puts "Writing file #{file_path}"

    output = ERB.new(template).result(binding)
    self.write_to_file(file_path, output)
  end
private
  def self.write_to_file(filename, contents)
    file = File.open(filename, 'w+')
    file.write contents
    file.close
  end
end

class StructureRefactorOutput
  def self.write_output(structure, output_path, overwrite = false)
    s = structure
    FileUtils.rm_rf(output_path) if overwrite
    FileUtils.mkdir(output_path)

    s.all_methods.each do |m|
      write_method_to_file(m, File.join(output_path, m.name.to_fortran_file))
    end
  end

  def self.write_method_to_file(m, file_path)
    puts "Writing file #{file_path}"

    output = m.source
    self.write_to_file(file_path, output)
  end
private
  def self.write_to_file(filename, contents)
    file = File.open(filename, 'w+')
    file.write contents
    file.close
  end
end

$directory = 'doc'
$output = StructureExtractorHtmlOutput
$overwrite = false

opts = OptionParser.new(ARGV) do |o|
  o.banner = 'Usage: struct.rb [options] source_directory'
  o.on('-d DIRECTORY', '--directory', 'Output directory') { |d| $directory = d}
  o.on('-t TITLE', '--title', 'Project title') { |t| $project_title = t}
  o.on('-h') { puts o; exit }
  o.on('-f', '--force', 'Force output folder overwrite') { $overwrite = true }
  o.on('-r', '--refactor') { $directory = 'refactor'; $output = StructureRefactorOutput }
  o.parse!
end
path = File.join(File.expand_path('.'), $directory)

s = StructureExtractor.new(File.expand_path(ARGV.last))
$output::write_output(s, path, $overwrite)

