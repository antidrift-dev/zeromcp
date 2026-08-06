tool description: "Echo a message",
     input: { message: "string" },
     route: { method: "POST", path: "/echo" }

execute do |args, ctx|
  { message: args['message'], echoed: true }
end
