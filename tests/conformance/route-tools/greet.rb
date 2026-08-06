tool description: "Greet someone by name",
     input: { name: "string" },
     route: { method: "GET", path: "/greet/:name" }

execute do |args, ctx|
  "Hello, #{args['name']}!"
end
