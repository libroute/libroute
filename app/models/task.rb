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
        puts "Error: #{result}"
      end
    rescue Exception => e
      self.status = :failed
      puts "FAILED! Error was:"
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
    data = JSON.parse(self.input)

    # Check version
    if data['version'] != 0.1
      return "Only version 0.1 input files are supported"
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
      #Docker::Image.build_from_tar(File.open(fname, 'r'), {'dockerfile' => im['dockerfile']}) do |v|
      #  if (log = JSON.parse(v)) && log.has_key?("stream")
      #    $stdout.puts log["stream"]
      #  end
      #end
      # https://github.com/libroute/python-classification.git
      logfn = Proc.new do |v|
        if (log = JSON.parse(v)) && log.has_key?("stream")
          $stdout.puts log["stream"]
        end
      end

      if im['source'].eql?('github')
        url = "https://github.com/#{im['user']}/#{im['repo']}.git"
        image = Docker::Image.build_from_tar(StringIO.new, {'remote'=>url}, &logfn)
      elsif im['source'].eql?('local')
        localdir = Rails.root + 'repos' + im['dir']
        image = Docker::Image.build_from_dir(localdir.to_s, &logfn)
      else
        return "Invalid source"
      end
      im['id'] = image.id
      im
    end

    # Preload data
    data['preload'].each do |pre|
      pre.each do |filename,val|
        puts "Storing task id #{self.id} with filename #{filename}"
        Blob.store(self.id, filename){|f| f.write(val.join("\n"))}
        puts "Done"
	#File.open(Rails.root + 'output' + self.id.to_s + filename,'wb'){|f| f.write(val.join("\n"))}
      end
    end


    # Run containers
    data['activities'].each do |act|
      # Find image
      puts data['images'].to_s
      puts act['image'].to_s

      image = data['images'].select{|im| im['name'].eql?(act['image'])}.first
      id = image['id']
      # Create container
      puts "Creating #{image['name']}"
      if act['cmd'].nil?
	c = Docker::Container.create('Image'=>id)
      else
	c = Docker::Container.create('Image'=>id, 'Cmd'=>act['cmd'])
      end

      # Send inputs
      act['inputs'].each do |k,v|
	puts "#{k}:#{v}"
        Blob.retrieve(self.id, k) do |io,size|
          Dockerio.store_file(c, v, io, size)
        end
	#fn = Rails.root + 'output' + self.id.to_s + k
	#fsize = File.size(fn)
	#File.open(fn, 'rb') do |io|
	#  Dockerio.store_file(c, v, io, fsize)
	#end
      end

      # Run
      puts "Starting #{image['name']}"
      puts "STDOUT:"
      c.tap(&:start).attach{ |stream, chunk| print "#{chunk}" }

      # Retrieve outputs
      puts "Retrieving outputs from #{image['name']}"
      act['outputs'].each do |k,v|
	puts "#{k}:#{v}"
        Blob.store(self.id,v) do |io|
          Dockerio.retrieve_file_advanced(c, k, io)
        end
	#fn = Rails.root + 'output' + self.id.to_s + v
	#File.open(fn, 'wb') do |f|
	#  Dockerio.retrieve_file_advanced(c, k, f)
	#end
      end

      # Cleanup
      puts "Cleaning up #{image['name']}"
      c.delete(:force=>true)
      
    end

  return true

  end

  def erase_data
    Blob.erase(self.id)
  end
end
