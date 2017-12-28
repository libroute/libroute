class CreateBlobs < ActiveRecord::Migration[5.1]
  def change
    create_table :blobs do |t|
      t.string :name
      t.string :uid
      t.references :task, foreign_key: true

      t.timestamps
    end
  end
end
