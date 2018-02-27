# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "webrick"
require "uri"
require "open-uri"
require "pathname"
require "tempfile"
require "json"
require "open3"

class LogStash::Inputs::RemoteLogProcessor < LogStash::Inputs::Base
	config_name "remote_log_processor"
	milestone 2

	default :codec, "plain"

	# Port where to listen for remote log queries
	#
	config :port, :validate => :number, :required => true

	private
	def send_event(output_queue, data, addtional_fields)
		@logger.debug? && @logger.debug("Received data", :fields => addtional_fields, :data => data)
		@codec.decode(data) do |event|
			decorate(event)
			addtional_fields.each do |key, value|
				event[key] = value
			end
			output_queue << event
		end
	end

	private
	def register_endpoint(output_queue)
		@server.mount_proc "/process" do |req, res|
			begin
				log_file = Tempfile.new("random")
				raise "GET requests are not supported" if res.request_method != "POST"
				raise "Not enough params" if !req.query.include?("source")
				additional_fields = {"source" => req.query["source"] }
				additional_fields.merge!(JSON.parse(req.query["additional_fields"])) if req.query.include?("additional_fields")

				parsed_url = URI.parse(req.query["source"])
				hostname = parsed_url.hostname
				source_filename = File.basename(parsed_url.path)
				source_extension = File.extname(parsed_url.path)

				raise "Bad parameters values" if parsed_url.hostname.empty?

				log_file.write(parsed_url.open.read)
				log_file.flush

				case source_extension
				when ".bz2", ".tbz"
					tar_opts = "-j"
				when ".gz", ".tgz"
					tar_opts = "-z"
				else
					tar_opts = nil
				end

				archive_contents = nil
				if tar_opts
					Open3.popen3("tar", "-t", "#{tar_opts}", "-f", File.path(log_file)) do |stdin, stdout, stderr, wait_thr|
						archive_contents = stdout.read.split
						raise "Archive is corrupted: #{stderr.read}" if !wait_thr.value.success?
					end

					if req.query.include?("mapping")
						mapping = JSON.parse(req.query["mapping"])
						raise "Bad parameters values" if mapping.empty?
						mapping.each do |path, description| 
							if archive_contents.include?(path)
								Open3.popen3("tar", "-x", "-O", "#{tar_opts}", "-f", File.path(log_file), "#{path}") \
								do |stdin, stdout, stderr, wait_thr|
									data = stdout.read
									additional_fields["description"] = description
									additional_fields["path"] = path
									raise "Failed to read #{source_filename}/#{path}: #{stderr.read}" if !wait_thr.value.success?
									send_event(output_queue, data, additional_fields)
								end
							else
								puts "#{path} is missing in #{source_filename}" # TODO: log warning there
							end
						end
					else
						Open3.popen3("tar", "-x", "-O", "#{tar_opts}", "-f", File.path(log_file)) do |stdin, stdout, stderr, wait_thr|
							data = stdout.read
							raise "Failed to read #{source_filename}: #{stderr.read}" if !wait_thr.value.success?
							send_event(output_queue, data, additional_fields)
						end
					end
				else
					data = IO.binread(File.path(log_file))
					if req.query.include?("mapping")
						mapping = JSON.parse(req.query["mapping"])
						if mapping.include?(source_filename)
							additional_fields["path"] = source_filename
							additional_fields["description"] = mapping[source_filename]
						end
					end
					send_event(output_queue, data, additional_fields)
				end
				response = {"message" => "Request has been processed successfully", "status" => "successful"}
				res.body = JSON.generate(response)
			ensure 
				log_file.close! if !log_file.nil?
			end # end of huge block to ensure we don't leave temp files opened after processing request
		end
	end

	public
	def register
		@logger.info("Starting remote_log_processor input listener", :port => "#{@port}")
		@server = WEBrick::HTTPServer.new :Port => @port
	end

	public
	def run(queue)
		trap "INT", "TERM" do @server.shutdown end
		register_endpoint(queue)
		@server.start
	ensure
		@server.shutdown
	end

	public
	def teardown

	end # def teardown
end # class LogStash::Inputs::RemoteLogProcessor