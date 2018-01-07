class Task < ApplicationRecord
  has_many :blobs, dependent: :destroy
  after_destroy :erase_data
  enum status: [:created, :pending, :running, :success, :failed, :error]
 
  def process
    self.status = :pending
    self.save
    self.delay.process_offline
  end

  def process_offline
    self.status = :running
    self.save
    begin
      result = self.run
      if result == true
        self.status = :success
      else
        self.status = :error
        Blob.store("log/error.txt", self.id) do |io|
          puts "#{result}"
          io.write "#{result}"
        end
      end
    rescue Exception => e
      self.status = :failed
      puts "FAILED"
      puts e.message
      puts e.backtrace.inspect
    ensure
      self.save
    end
  end

  def fetch(uri_str, limit = 10)
    # You should choose a better exception.
    raise ArgumentError, 'too many HTTP redirects' if limit == 0

    response = Net::HTTP.get_response(URI(uri_str))

    case response
    when Net::HTTPSuccess then
      response
    when Net::HTTPRedirection then
      location = response['location']
      warn "redirected to #{location}"
      fetch(location, limit - 1)
    else
      response.value
    end
  end

  def fname_from_im(im)
    hash = Digest::SHA256.hexdigest(im.to_s)
    fname = "repo.#{hash}.tar"
  end

  def run
 
    # Retrieve task info
    begin
      data = JSON.parse(self.input)
    rescue
      return "Error parsing JSON input definition"
    end

    # Check version
    if Task.version_ok?(data['version']) == false
      return "This version of input definition is not supported"
    end

    puts "Found #{data['images'].length} images"

    # Download tarball
    #data['images'].each do |im|
    #  fname = fname_from_im(im)
    #  if !File.exist?(fname)
    #    puts "Downloading #{im['user']}/#{im['repo']}/#{im['ref']}"
    #    response = fetch("https://api.github.com/repos/#{im['user']}/#{im['repo']}/tarball/#{im['ref']}")
    #    File.open(fname, 'wb') { |f| f.write(response.body) }
    #  else
    #    puts "Already cached #{im['user']}/#{im['repo']}/#{im['ref']}"
    #  end
    #end

    # Create data folder
    Dir.mkdir(Rails.root + 'output' + self.id.to_s)

    # Build containers
    data['images'].map! do |im|
      im_out = build_container(im)
      return nil if im_out.nil?
      im_out
    end

    # Download stores
    if !data['stores'].nil?
      data['stores'].each do |k,v|
        puts "Store #{k}:#{v}"
        if Blob.exist?(v)
          puts " -> using cache"
          next
        end
        uri = URI(v)
        Net::HTTP.start(uri.host, uri.port) do |http|
          request = Net::HTTP::Get.new uri.request_uri
          http.request request do |response|
            Blob.store(v) do |f|
              response.read_body do |chunk|
                f.write chunk
              end
            end
          end
        end
      end
    end

    # Preload data
    if !data['preload'].nil?
      data['preload'].each do |pre|
        pre.each do |filename,val|
          puts "Storing task id #{self.id} with filename #{filename}"
          Blob.store(filename, self.id){|f| f.write(val.join("\n"))}
          puts "Done"
        end
      end
    end

    # Run containers
    data['activities'].each do |act|

      # Find image
      puts data['images'].to_s
      puts act['image'].to_s

      image = data['images'].select{|im| im['name'].eql?(act['image'])}.first
      id = image['id']

      # Split if multi-input
      if act['multi-input'].nil?
        multi_out_filename = nil
        acts = [act]
      else
        lines = Blob.retrieve_lines(act['multi-input'].keys[0], self.id)
        puts "Parallel input: #{lines.count} activities"
        acts = Array.new
        lines.each do |l|
          act_new = act.dup
          act_new['multi-input-text'] = {l.strip => act['multi-input'].values[0]}
          acts.push act_new
        end
        multi_out_filename = act['multi-output'].values[0]
      end

      # Run each activity
      Blob.store(multi_out_filename, self.id) do |multi_out_io|
        acts.each_with_index do |act, idx|

	  # Create container
	  puts "Creating #{image['name']} (#{idx})"
	  if act['cmd'].nil?
	    c = Docker::Container.create('Image'=>id, 'Tty'=>false)
	  else
	    c = Docker::Container.create('Image'=>id, 'Tty'=>false, 'Cmd'=>act['cmd'])
	  end

	  # Send inputs
	  if !act['inputs'].nil?
	    act['inputs'].each do |k,v|
	      puts "#{k}:#{v}"
	      Blob.retrieve(k, self.id) do |io,size|
		Dockerio.store_file(c, v, io, size)
	      end
	    end
	  end

          # Send store-inputs
          if !act['store-inputs'].nil?
            act['store-inputs'].each do |ref,fn|
              bn = data['stores'][ref]
              return "Store #{ref} not found" if bn.nil?
              puts "#{ref} (#{bn}):#{fn}"
              Blob.retrieve(bn) do |io,size|
                Dockerio.store_file(c, fn, io, size)
              end
            end
          end

	  # Send multi-input
	  if !act['multi-input-text'].nil?
	    act['multi-input-text'].each do |k,v|
	      puts "VALUE #{k}:#{v}"
	      Dockerio.store_file(c, v, StringIO.new(k), k.length)
	    end
	  end

	  # Setup run thread
	  puts "Starting #{image['name']}"
	  t1 = Thread.new do
	    Blob.store("log/#{image['name']}.stdout.txt", self.id) do |io|
              Blob.store("log/#{image['name']}.stderr.txt", self.id) do |io_err|
	        c.tap(&:start).attach(:stream => true, :stdin => nil, :stdout => true, :stderr => true, :logs => true, :tty => false) do |stream, chunk|
		  if stream==:stdout
                    io.write(chunk)
                    io.flush
                  else
                    io_err.write(chunk)
                    io_err.flush
                  end
		  puts "#{chunk}"
                end
	      end
	    end
	  end

	  # Setup monitor thread
	  t2 = Thread.new do
	    while true
	      state = Docker::Container.all(all: true, filters: { id: [c.id] }.to_json).first.info['State'].eql?('exited')
	      if state == true
		puts "Detected container exit... waiting"
		sleep 1
		puts "Force complete"
		t1.kill
		Thread.exit
	      end
	    end
	  end

	  # Wait until run thread complete
	  t1.join

	  # Ensure monitor is killed
	  t2.kill

	  # Retrieve outputs
	  puts "Retrieving outputs from #{image['name']}"
	  if !act['outputs'].nil?
	    act['outputs'].each do |k,v|
	    puts "#{k}:#{v}"
	      Blob.store(v, self.id) do |io|
		Dockerio.retrieve_file_advanced(c, k, io)
	      end
	    end
	  end

	  # Multi-output
	  if !act['multi-output'].nil?
	    Dockerio.retrieve_file_advanced(c, act['multi-output'].keys[0], multi_out_io)
	  end

	  # Cleanup
	  puts "Cleaning up #{image['name']}"
	  c.delete(:force=>true)
      
        end # multi-activity
      end # multi-out
    end # base activity

  return true

  end

  def build_container(im)
      if im['source'].eql?('github')
        url = "https://github.com/#{im['user']}/#{im['repo']}.git"
        puts "Using #{url}"
        buildfn = Proc.new{|logfn| Docker::Image.build_from_tar(StringIO.new, {'remote'=>url}, &logfn)}
      elsif im['source'].eql?('local')
        localdir = Rails.root + 'repos' + im['dir']
        buildfn = Proc.new{|logfn| Docker::Image.build_from_dir(localdir.to_s, &logfn)}
      elsif im['source'].eql?('dockerfile')
        buildfn = Proc.new{|logfn| Docker::Image.build(im['contents'].join("\n"), &logfn)}
      else
        return nil
      end

      image = nil
      Blob.store("log/#{im['name']}.build.txt", self.id) do |io|
        logfn = Proc.new do |v|
          if (log = JSON.parse(v)) && log.has_key?("stream")
            io.write(log["stream"])
            io.flush
            puts log["stream"]
          end
        end
        image = buildfn.call(logfn)
      end

      im['id'] = image.id
      im
  end

  def erase_data
    Blob.erase(self.id)
  end

  def self.version_ok?(v)
    v_app_full = Rails.application.config.libroute_version
    v_app = v_app_full[1..-1].split('-')[0]
    Task.version_check(v.to_s, v_app)
   end

   def self.version_check(v, s) # v is given version, s is supported version
    v = v.split('.').map{|x| x.to_i}
    s = s.split('.').map{|x| x.to_i}
    (0..2).each do |ind|
      v_i = v[ind] || 0
      s_i = s[ind] || 0
      if v_i > s_i then return false end
      if v_i < s_i then return true end
    end
    return true
  end
end
