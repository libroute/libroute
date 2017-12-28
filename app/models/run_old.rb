class Run < ApplicationRecord

  def process
    sleep 10
    puts Docker::Image.all
    self.status = 2
    self.save
  end

end
