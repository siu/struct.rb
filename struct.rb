#!/usr/bin/env ruby
# encoding: UTF-8


# Fortran Structure extractor ;)
#

require 'rubygems'
require 'optparse'
require 'fileutils'
require 'erb'
require 'uv'
require 'graphviz'

$project_title = 'Unnamed'
FOOTER = %q{<p><em>Analysis by <a href="http://github.com/siu/struct.rb">struct.rb</a> - David Siñuela Pastor</em></p>}
TEMPLATE_DIR = 'templates'

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
end

class StructureExtractorHtmlOutput
  THEME = 'dawn'
  def self.write_output(structure, output_path)
    s = structure
    FileUtils.rm_r(output_path, :force => true)
    FileUtils.mkdir_p(output_path)
    FileUtils.cp_r(File.join($base_path, 'css'), output_path)
    write_index_to_file(structure, File.join(output_path, 'index.html'))

    s.all_methods.each do |m|
      write_method_to_file(m, File.join(output_path, m.name.to_html_page))
    end

    self.generate_graph(structure, output_path)
  end

  def self.generate_graph(structure, output_path)
    g = GraphViz::new( 'Structure', :type => :digraph)
    h = Hash.new
    
    structure.all_methods.each do |m|
      h[m.name] = g.add_node(m.to_s)
    end

    puts "Adding edges"
    structure.all_methods.each do |m|
      m.calls.each do |callee|
        puts "Adding edge from #{m.name} to #{callee.name}"
        if !h[m.name].nil? && !h[callee.name].nil?
          g.add_edge(h[m.name], h[callee.name])
        end
      end
    end

    g.output(:png => File.join(output_path, 'struct.png'))
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
    File.read(File.join($base_path, TEMPLATE_DIR, template))
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

$directory = 'doc/structure'
opts = OptionParser.new(ARGV) do |o|
  o.banner = 'Usage: struct.rb [options] source_directory'
  o.on('-d DIRECTORY', '--directory', 'Output directory') { |d| $directory = d}
  o.on('-t TITLE', '--title', 'Project title') { |t| $project_title = t}
  o.on('-h') { puts o; exit }
  o.parse!
end
path = File.join(File.expand_path('.'), $directory)

$base_path = File.expand_path(File.dirname(__FILE__))
s = StructureExtractor.new(File.expand_path(ARGV.last))
StructureExtractorHtmlOutput::write_output(s, path)
