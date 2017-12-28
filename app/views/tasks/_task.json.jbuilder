json.extract! task, :id, :input, :status, :created_at, :updated_at
json.url task_url(task, format: :json)
