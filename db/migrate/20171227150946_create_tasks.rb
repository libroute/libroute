class CreateTasks < ActiveRecord::Migration[5.1]
  def change
    create_table :tasks do |t|
      t.text :input
      t.integer :status

      t.timestamps
    end
  end
end
