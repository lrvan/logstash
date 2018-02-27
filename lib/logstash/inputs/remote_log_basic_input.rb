# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"

require "uri"
require "open-uri"
require "pathname"
require "tempfile"
require "archive"

# Stream events from remote files.
# Based on generic file.rb input
#
class LogStash::Inputs::RemoteLog < LogStash::Inputs::Base
  config_name "remote_log"
  milestone 2

  default :codec, "plain"

  # The URL to the file to use as an input.
  #
  config :url, :validate => :string, :required => true

  # If input file is archive specifies what files from it to process
  #
  config :archive_elements, :validate => :array

  public
  def register
    @logger.info("Registering remote_log input", :url => @url)
    if URI.extract(url).empty?
      raise ArgumentError.new("url parameter must contain valid URL to log resource")
    end
  end # def register

  public
  def run(queue)
    parsed_url = URI.parse(url)
    hostname = parsed_url.hostname
    log_name = File.basename(parsed_url.path)
    extension = File.extname(parsed_url.path)
    log_file = Tempfile.new("random")
    log_file.write(parsed_url.open.read)
    log_file.flush

    case extension
    when ".bz2", "tbz", "gz", "tgz"
      puts "got archive"
      archive_file = Archive.new(File.path(log_file))
      archive_file.each do | element, element_data |
        if archive_elements.defined? && archive_elements.include?(element.path)
          @logger.debug? && @logger.debug("Received data", :url => url, :path => File.path(log_file), :text => element_data)
          @codec.decode(element_data) do |event|
            decorate(event)
            event["host"] = hostname if !event.include?("host")
            event["source"] = url
            event["log_name"] = log_name
            queue << event
          end
        end
      end
    else
      data = IO.binread(File.path(log_file))
      @logger.debug? && @logger.debug("Received data", :url => url, :path => File.path(log_file), :text => data)
      @codec.decode(data) do |event|
        decorate(event)
        event["host"] = hostname if !event.include?("host")
        event["source"] = url
        event["log_name"] = log_name
        queue << event
      end
    end
    finished
  end # def run

  public
  def teardown

  end # def teardown
end # class LogStash::Inputs::RemoteLog