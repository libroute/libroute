class Dockerio

  def self.store_file(c, fn, contents_io, contents_size)

    # thread(contents_io -> TarWriter) -> container[archive_in_stream]

    r,w = IO.pipe('ASCII-8BIT')
    w.set_encoding('ASCII-8BIT')
    n_bytes = nil
    Thread.new do
      Gem::Package::TarWriter.new(w) do |tar|
        tar.add_file_simple(fn, 0777, contents_size) do |tar_io|
          n_bytes = self.copy_stream(contents_io, tar_io)
        end
      end
      w.close
    end
    # IO Pipe -> Container in
    c.archive_in_stream('/') do
      r.read(Excon.defaults[:chunk_size]).to_s
    end
  end

  def self.retrieve_file(c, k, f)
    data = c.read_file(k)
    f.write(data)
  end

  def self.retrieve_file_advanced(c,k,contents_io)

    # container[archive_out] -> TarReader -> contents_io
    r,w = IO.pipe('ASCII-8BIT')
    w.set_encoding('ASCII-8BIT')
    Thread.new do
      c.archive_out(k) do |chunk|
        w.write chunk
      end
      w.close
    end

    # Patch IO read object
    #   pos is read on init and seek must raise NameError to ensure reversion to read instead of seek
    r.define_singleton_method('seek'){|*args| raise NameError}
    r.define_singleton_method('pos'){return 0}

    Gem::Package::TarReader.new(r) do |tar|
      tar.each_with_index do |tar_io,idx|
        break if idx > 0
        self.copy_stream(tar_io, contents_io)
        tar_io.close
        contents_io.close
      end
    end

  end

  def self.copy_stream(r,w)
    n = 0
    while !(chk = r.read(1048576)).nil?
      w.write(chk)
      n += chk.length
    end
    n
  end
end
