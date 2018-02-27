require "webrick"
require "uri"
require "open-uri"
require "pathname"
require "tempfile"
require "tmpdir"
require "json"
require "open3"

def send_event(data, addtional_fields)
	puts "processed data length: " + data.length.to_s
	addtional_fields.each { |key, value|
		puts "#{key}: #{value}"
	}
end

server = WEBrick::HTTPServer.new :Port => 8000

trap "INT" do server.shutdown end

server.mount_proc "/process" do |req, res|
begin
	raise "GET requests are not supported" if res.request_method != "POST"
	raise "Not enough params" if !req.query.include?("source")
	
	parsed_url = URI.parse(req.query["source"])
	hostname = parsed_url.hostname
	source_filename = File.basename(parsed_url.path)
	source_extension = File.extname(parsed_url.path)

	raise "Bad parameters values" if parsed_url.hostname.empty?

	log_file = Tempfile.new("random") # TODO: add ensure to close temp file
	puts File.path(log_file) # TODO: remove this debug output
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

		if req.query.include?("log_names")
			log_names = JSON.parse(req.query["log_names"])
			raise "Bad parameters values" if log_names.empty?
			log_names.each { |orig_log_file, log_name| 
				if archive_contents.include?(orig_log_file)
					Open3.popen3("tar", "-x", "-O", "#{tar_opts}", "-f", File.path(log_file), "#{orig_log_file}") \
					do |stdin, stdout, stderr, wait_thr|
						data = stdout.read
						fields = {"source" => req.query["source"], "log_name" => log_name, 
							"orig_log_name" => orig_log_file}
						raise "Failed to read #{source_filename}/#{orig_log_file}: #{stderr.read}" if !wait_thr.value.success?
						send_event(data, fields)
					end
				else
					puts "#{orig_log_file} is missing in #{source_filename}" # TODO: log warning there
				end
			}
		else
			Open3.popen3("tar", "-x,", "-O", "#{tar_opts}", "-f", File.path(log_file)) do |stdin, stdout, stderr, wait_thr|
				data = stdout.read
				fields = {"source" => req.query["source"]}
				raise "Failed to read #{source_filename}: #{stderr.read}" if !wait_thr.value.success?
				send_event(data, fields)
			end
		end
	else
		data = IO.binread(File.path(log_file))
		fields = {"source" => req.query["source"]}
		if req.query.include?("log_names")
			log_names = JSON.parse(req.query["log_names"])
			if log_names.include?(source_filename)
				fields["orig_log_name"] = source_filename
				fields["log_name"] = log_names[source_filename]
			end
		end
		send_event(data, fields)
	end

	res.body += "\nURL has been opened successfully"
ensure
	log_file.close!
end
end

server.start