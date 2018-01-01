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
        Blob.store(self.id, "log/error.txt") do |io|
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
    data = JSON.parse(self.input)

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
      if im['source'].eql?('github')
        url = "https://github.com/#{im['user']}/#{im['repo']}.git"
        buildfn = Proc.new{|logfn| Docker::Image.build_from_tar(StringIO.new, {'remote'=>url}, &logfn)}
      elsif im['source'].eql?('local')
        localdir = Rails.root + 'repos' + im['dir']
        buildfn = Proc.new{|logfn| Docker::Image.build_from_dir(localdir.to_s, &logfn)}
      elsif im['source'].eql?('dockerfile')
        buildfn = Proc.new{|logfn| Docker::Image.build(im['contents'].join("\n"), &logfn)}
      else
        return "Invalid source"
      end

      image = nil
      Blob.store(self.id, "log/#{im['name']}.build.txt") do |io|
        logfn = Proc.new do |v|
          if (log = JSON.parse(v)) && log.has_key?("stream")
            io.write(log["stream"])
            puts log["stream"]
          end
        end
        image = buildfn.call(logfn)
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
	c = Docker::Container.create('Image'=>id, 'Tty'=>false)
      else
	c = Docker::Container.create('Image'=>id, 'Tty'=>false, 'Cmd'=>act['cmd'])
      end

      # Send inputs
      act['inputs'].each do |k,v|
	puts "#{k}:#{v}"
        Blob.retrieve(self.id, k) do |io,size|
          Dockerio.store_file(c, v, io, size)
        end
      end

      # Setup run thread
      puts "Starting #{image['name']}"
      t1 = Thread.new do
        Blob.store(self.id, "log/#{image['name']}.txt") do |io|
           c.tap(&:start).attach(:stream => true, :stdin => nil, :stdout => true, :stderr => true, :logs => true, :tty => false) do |stream, chunk|
            io.write(chunk)
            puts "#{chunk}"
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
      act['outputs'].each do |k,v|
	puts "#{k}:#{v}"
        Blob.store(self.id,v) do |io|
          Dockerio.retrieve_file_advanced(c, k, io)
        end
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
      puts "comparing #{v_i} to #{s_i}"
      if v_i > s_i then return false end
      if v_i < s_i then return true end
    end
    return true
  end
end
