class Blob < ApplicationRecord
  belongs_to :task

  EXTS = ['.txt','.png']

  def set_defaults
    self.uid = SecureRandom.hex
  end

  def self.retrieve(taskid, name)
    d = basedir(taskid)
    b = Blob.where(task_id: taskid, name: name).last
    return nil if b.nil?
    size = File.size(d + b.uid)
    File.open(d + b.uid, 'rb') do |f|
      yield(f,size)
    end
  end

  def self.store(taskid, name)
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
    File.open(d + b.uid, 'wb') do |f|
      yield(f)
    end
    b.save
  end

  def self.erase(taskid)
    FileUtils.rm_rf(basedir(taskid))
  end

  def self.basedir(runid)
    return Rails.root + 'output' + runid.to_s
  end
end
