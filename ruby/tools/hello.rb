tool description: "Say hello to someone",
     input: { name: "string" }

execute do |args, ctx|
  "Hello, #{args['name']}!"
end
