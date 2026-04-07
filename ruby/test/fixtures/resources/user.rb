resource description: "Fetch user by ID",
        mime_type: "application/json",
        uri_template: "user:///{id}"

read do |params|
  "{\"id\":\"#{params['id']}\",\"name\":\"User #{params['id']}\"}"
end
