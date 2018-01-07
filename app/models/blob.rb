class Blob < ApplicationRecord
  belongs_to :task, required: false

  EXTS = ['.txt','.png']

  def set_defaults
    self.uid = SecureRandom.hex
  end

  def self.exist?(name, taskid=0)
    !Blob.where(task_id: taskid, name: name).first.nil?
  end

  def self.retrieve(name, taskid=0)
    d = basedir(taskid)
    b = Blob.where(task_id: taskid, name: name).last
    return nil if b.nil?
    size = File.size(d + b.uid)
    File.open(d + b.uid, 'rb') do |f|
      yield(f,size)
    end
  end
 
  def self.retrieve_lines(name, taskid=0)
    ll = Array.new
    Blob.retrieve(taskid, name) do |f|
      f.each_line do |l|
        ll.push l
      end
    end
    ll
  end

  def self.store(name, taskid=0)
    if name.nil?
      yield(nil)
      return
    end
    ext = name[-4..-1]
    ext ||= ''
    ext.downcase!
    EXTS.map{|e| e.eql?(ext)}.any? ? allow_ext = true : allow_ext = false
    d = basedir(taskid)
    Dir.mkdir(d) if Dir.exist?(d) == false
    b = Blob.new
    b.uid = SecureRandom.hex
    b.uid = b.uid + ext if allow_ext
    b.name = name
    b.task_id = taskid
    b.save
    File.open(d + b.uid, 'wb') do |f|
      yield(f)
    end
  end

  def self.erase(taskid=0)
    FileUtils.rm_rf(basedir(taskid))
  end

  def self.basedir(runid)
    return Rails.root + 'output' + runid.to_s
  end
end
