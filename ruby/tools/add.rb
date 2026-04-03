tool description: "Add two numbers together",
     input: { a: "number", b: "number" }

execute do |args, ctx|
  { sum: args['a'] + args['b'] }
end
